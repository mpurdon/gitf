defmodule Hive.Bee.Worker do
  @moduledoc """
  GenServer managing a single bee's lifecycle.

  Each bee is a Claude Code agent working on one job within a comb.
  The Worker provisions an isolated worktree (cell), spawns Claude
  headless with the job prompt, and reports results back to the Queen
  via waggle messages.

  ## Lifecycle

      start_link -> init -> {:continue, :provision}
                          -> create cell
                          -> update DB record
                          -> generate settings
                          -> spawn Claude headless
                          -> accumulate port output
                          -> exit_status 0 -> success -> waggle queen
                          -> exit_status N -> failure -> waggle queen

  ## Registration

  Workers register via `Hive.Registry` under `{:bee, bee_id}` for
  easy lookup and to prevent duplicate workers for the same bee.

  ## Restart strategy

  Workers use `restart: :temporary` because the Queen decides whether
  and how to retry failed bees -- not the supervisor.
  """

  use GenServer
  require Logger

  alias Hive.Store

  @registry Hive.Registry

  # -- Types -------------------------------------------------------------------

  @type state :: %{
          bee_id: String.t(),
          job_id: String.t(),
          comb_id: String.t(),
          cell_id: String.t() | nil,
          port: port() | nil,
          status: :provisioning | :running | :done | :failed,
          hive_root: String.t(),
          output: iodata(),
          parsed_events: [map()]
        }

  # -- Child spec --------------------------------------------------------------

  def child_spec(opts) do
    bee_id = Keyword.fetch!(opts, :bee_id)

    %{
      id: {__MODULE__, bee_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  # -- Client API --------------------------------------------------------------

  @doc """
  Starts a Bee Worker process.

  ## Required options

    * `:bee_id` - the bee's database ID
    * `:job_id` - the job being worked on
    * `:comb_id` - the comb (repository) to work in
    * `:hive_root` - the hive workspace root directory

  ## Optional

    * `:prompt` - explicit prompt text (overrides job title/description)
    * `:claude_executable` - path to the executable to spawn (for testing)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    bee_id = Keyword.fetch!(opts, :bee_id)
    name = via(bee_id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the current status of a bee worker by bee_id."
  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(bee_id) do
    case lookup(bee_id) do
      {:ok, pid} -> {:ok, GenServer.call(pid, :status)}
      :error -> {:error, :not_found}
    end
  end

  @doc "Gracefully stops a bee worker."
  @spec stop(String.t()) :: :ok | {:error, :not_found}
  def stop(bee_id) do
    case lookup(bee_id) do
      {:ok, pid} -> GenServer.call(pid, :stop)
      :error -> {:error, :not_found}
    end
  end

  @doc "Looks up a bee worker PID via the Registry."
  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(bee_id) do
    case Registry.lookup(@registry, {:bee, bee_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  # -- GenServer callbacks -----------------------------------------------------

  @impl true
  def init(opts) do
    bee_id = Keyword.fetch!(opts, :bee_id)
    job_id = Keyword.fetch!(opts, :job_id)
    comb_id = Keyword.fetch!(opts, :comb_id)
    hive_root = Keyword.fetch!(opts, :hive_root)

    state = %{
      bee_id: bee_id,
      job_id: job_id,
      comb_id: comb_id,
      cell_id: nil,
      port: nil,
      status: :provisioning,
      hive_root: hive_root,
      output: [],
      parsed_events: [],
      opts: opts
    }

    {:ok, state, {:continue, :provision}}
  end

  @impl true
  def handle_continue(:provision, state) do
    case provision(state) do
      {:ok, updated_state} ->
        {:noreply, updated_state}

      {:error, reason} ->
        Logger.error("Bee #{state.bee_id} failed to provision: #{inspect(reason)}")
        mark_failed(state, "Provision failed: #{inspect(reason)}")
        {:stop, :normal, %{state | status: :failed}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      bee_id: state.bee_id,
      job_id: state.job_id,
      comb_id: state.comb_id,
      cell_id: state.cell_id,
      status: state.status
    }

    {:reply, reply, state}
  end

  def handle_call(:stop, _from, state) do
    state = do_stop(state)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    events = Hive.Runtime.StreamParser.parse_chunk(data)
    update_progress(state.bee_id, events)
    {:noreply, %{state | output: [state.output, data], parsed_events: state.parsed_events ++ events}}
  end

  def handle_info({port, {:exit_status, 0}}, %{port: port} = state) do
    Logger.info("Bee #{state.bee_id} completed successfully")
    mark_success(state)
    {:stop, :normal, %{state | status: :done, port: nil}}
  end

  def handle_info({port, {:exit_status, exit_code}}, %{port: port} = state) do
    Logger.warning("Bee #{state.bee_id} exited with status #{exit_code}")
    output = IO.iodata_to_binary(state.output)
    mark_failed(state, "Exit code #{exit_code}: #{String.slice(output, 0, 500)}")
    {:stop, :normal, %{state | status: :failed, port: nil}}
  end

  def handle_info(msg, state) do
    Logger.debug("Bee #{state.bee_id} received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.port != nil and port_alive?(state.port) do
      Port.close(state.port)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  # -- Private: provisioning ---------------------------------------------------

  defp provision(state) do
    if Keyword.get(state.opts, :revive, false) do
      provision_revive(state)
    else
      provision_fresh(state)
    end
  end

  defp provision_fresh(state) do
    with {:ok, cell} <- create_cell(state),
         :ok <- update_bee_working(state, cell),
         :ok <- maybe_transition_job(state),
         :ok <- maybe_ensure_agent(state, cell),
         {:ok, port} <- spawn_process(state, cell) do
      {:ok,
       %{
         state
         | cell_id: cell.id,
           port: port,
           status: :running
       }}
    end
  end

  defp provision_revive(state) do
    cell_id = Keyword.fetch!(state.opts, :cell_id)

    with {:ok, cell} <- Hive.Cell.get(cell_id),
         :ok <- update_bee_working(state, cell),
         {:ok, port} <- spawn_process(state, cell) do
      {:ok, %{state | cell_id: cell.id, port: port, status: :running}}
    end
  end

  defp create_cell(state) do
    Hive.Cell.create(state.comb_id, state.bee_id, hive_root: state.hive_root)
  end

  defp update_bee_working(state, cell) do
    case Store.get(:bees, state.bee_id) do
      nil ->
        {:error, :bee_not_found}

      bee ->
        updated = Map.merge(bee, %{status: "working", cell_path: cell.worktree_path, pid: inspect(self())})
        Store.put(:bees, updated)
        :ok
    end
  end

  defp maybe_transition_job(state) do
    case Hive.Jobs.get(state.job_id) do
      {:ok, %{status: "assigned"}} ->
        case Hive.Jobs.start(state.job_id) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp spawn_process(state, cell) do
    prompt = build_prompt(state)
    executable = Keyword.get(state.opts, :claude_executable)

    case executable do
      nil ->
        # Settings are generated during cell creation (Hive.Cell.create/3)
        Hive.Runtime.Claude.spawn_headless(cell.worktree_path, prompt)

      exe_path ->
        # Testing path: use provided executable instead of Claude
        spawn_test_executable(exe_path, prompt, cell)
    end
  end

  defp spawn_test_executable(exe_path, prompt, cell) do
    port =
      Port.open({:spawn_executable, exe_path}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: [prompt],
        cd: cell.worktree_path
      ])

    {:ok, port}
  end

  defp build_prompt(state) do
    case Keyword.get(state.opts, :prompt) do
      nil ->
        case Hive.Jobs.get(state.job_id) do
          {:ok, job} ->
            if job.description do
              "#{job.title}\n\n#{job.description}"
            else
              job.title
            end

          {:error, _} ->
            "Work on job #{state.job_id}"
        end

      prompt ->
        prompt
    end
  end

  # -- Private: completion handling --------------------------------------------

  defp mark_success(state) do
    update_bee_status(state.bee_id, "stopped")

    case Hive.Jobs.get(state.job_id) do
      {:ok, %{status: "done"}} -> :ok
      _ ->
        Hive.Jobs.complete(state.job_id)
        Hive.Jobs.unblock_dependents(state.job_id)
    end

    record_costs_from_events(state)

    # Validation pipeline
    case maybe_validate(state) do
      :ok ->
        maybe_check_conflicts(state)
        maybe_merge_back(state)

        session_id = Hive.Runtime.StreamParser.extract_session_id(state.parsed_events)
        body = "Job #{state.job_id} completed successfully"
        body = if session_id, do: body <> "\nSession ID: #{session_id}", else: body

        Hive.Waggle.send(state.bee_id, "queen", "job_complete", body)

      {:error, reason} ->
        Logger.warning("Validation failed for bee #{state.bee_id}: #{inspect(reason)}")
        Hive.Jobs.fail(state.job_id)
        Hive.Waggle.send(state.bee_id, "queen", "validation_failed",
          "Job #{state.job_id} failed validation: #{inspect(reason)}")
    end

    Hive.Progress.clear(state.bee_id)
  end

  defp mark_failed(state, reason) do
    update_bee_status(state.bee_id, "crashed")
    Hive.Jobs.fail(state.job_id)
    record_costs_from_events(state)
    Hive.Progress.clear(state.bee_id)

    Hive.Waggle.send(
      state.bee_id,
      "queen",
      "job_failed",
      "Job #{state.job_id} failed: #{reason}"
    )
  end

  defp record_costs_from_events(state) do
    state.parsed_events
    |> Hive.Runtime.StreamParser.extract_costs()
    |> Enum.each(fn cost_data ->
      Hive.Costs.record(state.bee_id, cost_data)
    end)
  end

  defp maybe_ensure_agent(state, cell) do
    case Hive.Jobs.get(state.job_id) do
      {:ok, job} ->
        case Store.get(:combs, cell.comb_id) do
          nil ->
            :ok

          comb when comb.path != nil ->
            Hive.AgentProfile.ensure_agent(comb.path, %{title: job.title, description: job.description})
            Hive.AgentProfile.install_agents(comb.path, cell.worktree_path)
            :ok

          _comb ->
            :ok
        end

      {:error, _} ->
        :ok
    end
  end

  defp maybe_merge_back(state) do
    if state.cell_id do
      case Hive.Merge.merge_back(state.cell_id) do
        {:ok, strategy} ->
          Logger.info("Merge strategy #{strategy} applied for bee #{state.bee_id}")

        {:error, reason} ->
          Logger.warning("Merge-back failed for bee #{state.bee_id}: #{inspect(reason)}")
          Hive.Waggle.send(
            state.bee_id,
            "queen",
            "merge_failed",
            "Merge failed for #{state.cell_id}: #{inspect(reason)}"
          )
      end
    end
  rescue
    e ->
      Logger.warning("Merge-back error: #{inspect(e)}")
  end

  defp update_progress(bee_id, events) do
    Enum.each(events, fn event ->
      case event do
        %{"type" => "tool_use", "name" => tool} ->
          file = get_in(event, ["input", "file_path"]) || ""
          Hive.Progress.update(bee_id, %{tool: tool, file: file, message: "Using #{tool}"})

        %{"type" => "assistant", "content" => content} when is_binary(content) ->
          Hive.Progress.update(bee_id, %{tool: nil, file: nil, message: String.slice(content, 0, 120)})

        _ ->
          :ok
      end
    end)
  rescue
    _ -> :ok
  end

  defp maybe_validate(state) do
    case {state.cell_id, Hive.Jobs.get(state.job_id)} do
      {cell_id, {:ok, job}} when not is_nil(cell_id) ->
        case Hive.Validator.validate(state.bee_id, job, cell_id) do
          {:ok, _verdict} -> :ok
          {:error, reason, _details} -> {:error, reason}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp maybe_check_conflicts(state) do
    if state.cell_id do
      case Hive.Conflict.check(state.cell_id) do
        {:ok, :clean} ->
          :ok

        {:error, :conflicts, files} ->
          Logger.warning("Conflicts detected for bee #{state.bee_id}: #{inspect(files)}")
          Hive.Waggle.send(state.bee_id, "queen", "merge_conflict_warning",
            "Conflicts in: #{Enum.join(files, ", ")}")

        _ ->
          :ok
      end
    end
  rescue
    _ -> :ok
  end

  defp do_stop(state) do
    if state.port != nil and port_alive?(state.port) do
      Port.close(state.port)
    end

    update_bee_status(state.bee_id, "stopped")
    %{state | status: :done, port: nil}
  rescue
    ArgumentError -> %{state | status: :done, port: nil}
  end

  defp update_bee_status(bee_id, status) do
    case Store.get(:bees, bee_id) do
      nil -> :ok
      bee -> Store.put(:bees, %{bee | status: status})
    end
  end

  defp port_alive?(port) do
    Port.info(port) != nil
  rescue
    ArgumentError -> false
  end

  defp via(bee_id) do
    {:via, Registry, {@registry, {:bee, bee_id}}}
  end
end
