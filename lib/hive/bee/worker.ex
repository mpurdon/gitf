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
          task: Task.t() | nil,
          execution_mode: :api | :cli | :ollama | :bedrock,
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

    # Set correlation IDs for structured logging
    Hive.Logger.set_bee_context(bee_id, job_id)

    state = %{
      bee_id: bee_id,
      job_id: job_id,
      comb_id: comb_id,
      cell_id: nil,
      port: nil,
      task: nil,
      execution_mode: Hive.Runtime.ModelResolver.execution_mode(),
      status: :provisioning,
      hive_root: hive_root,
      output: [],
      parsed_events: [],
      opts: opts,
      checkpoint_timer: schedule_checkpoint()
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
    events = Hive.Runtime.Models.parse_output(data)
    update_progress(state.bee_id, events)
    
    # Track context usage from events
    track_context_usage(state.bee_id, events)

    {:noreply,
     %{state | output: [state.output, data], parsed_events: Enum.reverse(events) ++ state.parsed_events}}
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

  # -- API mode: Task completion -----------------------------------------------

  def handle_info({ref, {:ok, result}}, %{task: %Task{ref: ref}} = state) do
    # Task completed successfully — treat like exit_status 0
    Process.demonitor(ref, [:flush])
    Logger.info("Bee #{state.bee_id} API task completed successfully")

    # Convert agent loop result to parsed events + output
    events = Map.get(result, :events, [])
    text = Map.get(result, :text, "")

    state = %{state |
      parsed_events: Enum.reverse(events) ++ state.parsed_events,
      output: [state.output, text],
      task: nil
    }

    mark_success(state)
    {:stop, :normal, %{state | status: :done}}
  end

  def handle_info({ref, {:error, reason}}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Logger.warning("Bee #{state.bee_id} API task failed: #{inspect(reason)}")

    # Try model fallback before giving up
    case maybe_fallback_model(state) do
      {:ok, new_task, fallback_model} ->
        Logger.info("Bee #{state.bee_id} falling back to model #{fallback_model}")
        {:noreply, %{state | task: new_task, fallback_attempted: true}}

      :no_fallback ->
        # Record API failure in circuit breaker so global outage is detected
        Hive.CircuitBreaker.call("api:llm", fn -> {:error, reason} end)
        mark_failed(state, "API error: #{inspect(reason)}")
        {:stop, :normal, %{state | status: :failed, task: nil}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    # Task process crashed
    Logger.error("Bee #{state.bee_id} API task crashed: #{inspect(reason)}")
    mark_failed(state, "Task crash: #{inspect(reason)}")
    {:stop, :normal, %{state | status: :failed, task: nil}}
  end

  def handle_info({:agent_progress, bee_id, event}, state) when bee_id == state.bee_id do
    progress = format_agent_progress(event)
    Hive.Progress.update(state.bee_id, progress)
    {:noreply, state}
  end

  def handle_info(:checkpoint, state) do
    if state.status == :running do
      checkpoint_data = build_checkpoint_data(state)
      Hive.Checkpoint.save(state.bee_id, checkpoint_data)
    end

    {:noreply, %{state | checkpoint_timer: schedule_checkpoint()}}
  end

  def handle_info(:context_handoff, %{status: :running} = state) do
    Logger.info("Bee #{state.bee_id} initiating proactive context handoff")

    # Create handoff with current state
    Hive.Handoff.create(state.bee_id)

    # Stop the current process (port/task)
    state = do_stop(state)

    # Reset the job to pending so it can be re-spawned with handoff context
    case Hive.Jobs.get(state.job_id) do
      {:ok, job} ->
        Store.put(:jobs, %{job | status: "pending"})
      _ ->
        :ok
    end

    # Notify Queen that bee handed off — Queen's job spawner will pick it up
    Hive.Waggle.send(
      state.bee_id,
      "queen",
      "context_handoff",
      "Bee #{state.bee_id} handed off job #{state.job_id} due to context exhaustion"
    )

    {:stop, :normal, %{state | status: :done}}
  end

  def handle_info(:context_handoff, state) do
    # Not running, ignore
    {:noreply, state}
  end

  def handle_info(:verify_beacon, %{status: :running} = state) do
    alive? =
      cond do
        state.task != nil -> Process.alive?(state.task.pid)
        state.port != nil -> port_alive?(state.port)
        true -> false
      end

    has_output? = state.parsed_events != []

    cond do
      not alive? ->
        Logger.warning("Beacon check failed: bee #{state.bee_id} process is dead after 10s")
        mark_failed(state, "Process died within 10 seconds of spawning")
        {:stop, :normal, %{state | status: :failed}}

      not has_output? ->
        Logger.warning("Beacon check: bee #{state.bee_id} alive but no output after 10s")
        # Process is alive but silent -- not fatal, just log a warning
        {:noreply, state}

      true ->
        Logger.debug("Beacon check passed for bee #{state.bee_id}")
        {:noreply, state}
    end
  end

  def handle_info(:verify_beacon, state) do
    # Bee is no longer running (already completed or failed), ignore
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Bee #{state.bee_id} received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # If bee was actively running, preserve context via checkpoint + handoff
    if state.status == :running do
      try do
        # Save final checkpoint so handoff has latest progress
        checkpoint_data = build_checkpoint_data(state)
        Hive.Checkpoint.save(state.bee_id, checkpoint_data)

        # Create handoff so replacement bee has context
        Hive.Handoff.create(state.bee_id)
        Logger.info("Bee #{state.bee_id} crash handoff saved")
      rescue
        e ->
          Logger.debug("Crash handoff failed for bee #{state.bee_id}: #{inspect(e)}")
      end
    end

    # Mark bee as crashed if still in an active state
    if state.status in [:provisioning, :running] do
      update_bee_status(state.bee_id, "crashed")
    end

    # Shutdown API task if running (allow 2s for graceful cleanup)
    if state.task != nil do
      Task.shutdown(state.task, 2_000)
    end

    # Close CLI port if running
    try do
      if state.port != nil and port_alive?(state.port) do
        Port.close(state.port)
      end
    rescue
      _ -> :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  # -- Private: agent progress formatting --------------------------------------

  defp format_agent_progress(%{type: :started} = event) do
    model = Map.get(event, :model, "unknown")
    %{tool: nil, file: nil, message: "Started (model: #{model})"}
  end

  defp format_agent_progress(%{type: :iteration} = event) do
    iter = Map.get(event, :iteration, 0)
    max = Map.get(event, :max_iterations, "?")
    %{tool: nil, file: nil, message: "Thinking (iteration #{iter + 1}/#{max})"}
  end

  defp format_agent_progress(%{type: :tool_call} = event) do
    tool = Map.get(event, :tool, "unknown")
    args = Map.get(event, :args, %{})
    file = Map.get(args, "file_path") || Map.get(args, "path") || ""

    %{tool: tool, file: file, message: "Using #{tool}"}
  end

  defp format_agent_progress(%{type: :completed} = event) do
    iters = Map.get(event, :iterations, 0)
    %{tool: nil, file: nil, message: "Completed in #{iters} iteration(s)"}
  end

  defp format_agent_progress(event) do
    %{
      tool: Map.get(event, :tool),
      file: nil,
      message: "#{Map.get(event, :type, :progress)}: #{Map.get(event, :tool, "working")}"
    }
  end

  # -- Private: provisioning ---------------------------------------------------

  defp provision(state) do
    # Rate limit agent spawning to avoid API throttling
    case Hive.RateLimiter.acquire(Hive.RateLimiter) do
      :ok -> :ok
      {:ok, delay_ms} -> Process.sleep(delay_ms)
    end

    if Keyword.get(state.opts, :revive, false) do
      provision_revive(state)
    else
      provision_fresh(state)
    end
  end

  defp provision_fresh(state) do
    # Enrich logging metadata with quest_id
    is_phase_job =
      case Hive.Jobs.get(state.job_id) do
        {:ok, job} ->
          Hive.Logger.set_bee_context(state.bee_id, state.job_id, job.quest_id)
          Map.get(job, :phase_job, false)

        _ ->
          false
      end

    with {:ok, cell} <- create_cell(state),
         :ok <- update_bee_working(state, cell),
         :ok <- maybe_transition_job(state),
         :ok <- maybe_ensure_agent(state, cell) do
      # Apply role-based tool restrictions via settings.local.json
      role = role_for_job(state.job_id)
      Hive.Runtime.Settings.generate_role_settings(role, cell.worktree_path)

      # Pre-dispatch: write job instructions so Claude Code has context at boot
      write_pre_dispatch(cell.worktree_path, state.job_id)

      # Build task-specific skill for non-phase jobs (works for both API and CLI)
      unless is_phase_job do
        maybe_build_task_skill(build_prompt(state), cell.worktree_path, state.job_id)
      end

      case spawn_process_with_timeout(state, cell) do
        {:ok, handle} ->
          # Schedule beacon verification to confirm the process actually started
          Process.send_after(self(), :verify_beacon, 10_000)

          if is_struct(handle, Task) do
            {:ok, %{state | cell_id: cell.id, task: handle, status: :running}}
          else
            {:ok, %{state | cell_id: cell.id, port: handle, status: :running}}
          end

        {:error, reason} ->
          # Rollback: clean up the cell/worktree on spawn failure
          Logger.warning("Spawn failed for bee #{state.bee_id}, rolling back cell #{cell.id}")
          rollback_cell(cell.id)
          {:error, reason}
      end
    else
      {:error, _reason} = err ->
        # If cell was created but a later step failed, attempt cleanup.
        # We check whether cell_id is set by looking at state -- if create_cell
        # succeeded but a subsequent step failed, the cell variable is not in scope
        # here, so we look it up by bee_id.
        rollback_cell_for_bee(state.bee_id)
        err
    end
  end

  defp provision_revive(state) do
    cell_id = Keyword.fetch!(state.opts, :cell_id)

    with {:ok, cell} <- Hive.Cell.get(cell_id),
         :ok <- update_bee_working(state, cell),
         {:ok, handle} <- spawn_process(state, cell) do
      if is_struct(handle, Task) do
        {:ok, %{state | cell_id: cell.id, task: handle, status: :running}}
      else
        {:ok, %{state | cell_id: cell.id, port: handle, status: :running}}
      end
    end
  end

  defp create_cell(state) do
    Hive.Cell.create(state.comb_id, state.bee_id, hive_root: state.hive_root)
  end

  defp role_for_job(job_id) do
    case Hive.Jobs.get(job_id) do
      {:ok, %{scout: true}} -> :scout
      _ -> :builder
    end
  end

  defp update_bee_working(state, cell) do
    case Store.get(:bees, state.bee_id) do
      nil ->
        {:error, :bee_not_found}

      bee ->
        updated =
          Map.merge(bee, %{status: "working", cell_path: cell.worktree_path, pid: inspect(self())})

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

  @spawn_timeout_ms 30_000

  defp spawn_process_with_timeout(state, cell) do
    task = Task.async(fn -> spawn_process(state, cell) end)

    case Task.yield(task, @spawn_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil ->
        Logger.error("Bee #{state.bee_id} spawn timed out after #{@spawn_timeout_ms}ms")
        {:error, :spawn_timeout}
    end
  end

  defp spawn_process(state, cell) do
    prompt = build_prompt(state)
    executable = Keyword.get(state.opts, :claude_executable)

    # Get the assigned model from the bee record
    model =
      case Store.get(:bees, state.bee_id) do
        %{assigned_model: model} when is_binary(model) -> model
        _ -> nil
      end

    # Build spawn options with model
    spawn_opts =
      if model do
        [model: model]
      else
        []
      end

    case executable do
      nil when state.execution_mode in [:api, :ollama, :bedrock] ->
        # API mode: run agent loop in a Task
        spawn_api_task(prompt, cell.worktree_path, spawn_opts, state)

      nil ->
        # CLI mode: settings are generated during cell creation (Hive.Cell.create/3)
        Hive.Runtime.Models.spawn_headless(prompt, cell.worktree_path, spawn_opts)

      exe_path ->
        # Testing path: use provided executable instead of Claude
        spawn_test_executable(exe_path, prompt, cell)
    end
  end

  defp spawn_api_task(prompt, working_dir, spawn_opts, state) do
    bee_id = state.bee_id

    # Determine tool_set based on phase job type
    tool_set =
      case Hive.Jobs.get(state.job_id) do
        {:ok, %{phase_job: true, phase: phase}} when phase in ["research", "requirements", "review", "validation"] ->
          :readonly

        _ ->
          :standard
      end

    agent_opts =
      spawn_opts
      |> Keyword.put(:tool_set, tool_set)
      |> Keyword.put(:include_dynamic, true)
      |> Keyword.put(:on_progress, fn event ->
        send(self(), {:agent_progress, bee_id, event})
      end)

    task = Task.async(fn ->
      Hive.Runtime.AgentLoop.run(prompt, working_dir, agent_opts)
    end)

    {:ok, task}
  end

  defp maybe_build_task_skill(_prompt, working_dir, job_id) do
    skill_path = Path.join([working_dir, ".claude", "agents", "task-skill.md"])

    # Check if a recent skill file already exists (skip regeneration on retries)
    if task_skill_fresh?(skill_path) do
      Logger.debug("Task skill already exists and is fresh for job #{job_id}, skipping")
      :ok
    else
      job_info =
        case Hive.Jobs.get(job_id) do
          {:ok, job} -> job
          _ -> nil
        end

      if is_nil(job_info) do
        :ok
      else
        do_build_task_skill(job_info, working_dir, job_id)
      end
    end
  rescue
    e ->
      Logger.debug("Task skill building failed (non-fatal): #{inspect(e)}")
      :ok
  end

  defp task_skill_fresh?(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} ->
        # Convert file mtime to Unix timestamp for comparison
        mtime_seconds = :calendar.datetime_to_gregorian_seconds(mtime) -
          :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})
        now_seconds = System.os_time(:second)
        # Consider fresh if written within the last hour
        now_seconds - mtime_seconds < 3600

      {:error, _} ->
        false
    end
  end

  defp do_build_task_skill(job_info, working_dir, job_id) do
    title = Map.get(job_info, :title, "")
    description = Map.get(job_info, :description, "")
    target_files = Map.get(job_info, :target_files, []) |> List.wrap() |> Enum.join(", ")
    acceptance = Map.get(job_info, :acceptance_criteria, "")

    research_prompt = """
    You are a senior software engineer preparing to implement a task.
    Research best practices and create a concise implementation guide.

    Task: #{title}
    Description: #{description}
    #{if target_files != "", do: "Target files: #{target_files}", else: ""}
    #{if acceptance != "", do: "Acceptance criteria: #{acceptance}", else: ""}

    Provide:
    1. Key patterns and best practices for this type of change
    2. Common pitfalls to avoid
    3. Recommended implementation approach
    4. Testing strategy

    Be concise — this will be loaded as context for the implementing agent.
    Keep under 500 words.
    """

    case Hive.Runtime.Models.generate_text(research_prompt, model: "haiku", max_tokens: 1024) do
      {:ok, skill_content} when is_binary(skill_content) and skill_content != "" ->
        agents_dir = Path.join([working_dir, ".claude", "agents"])
        File.mkdir_p!(agents_dir)
        skill_path = Path.join(agents_dir, "task-skill.md")
        File.write!(skill_path, skill_content)
        Logger.info("Built task skill for job #{job_id}")

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.debug("Task skill research failed (non-fatal): #{inspect(e)}")
      :ok
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
      {:ok, %{status: "done"}} ->
        :ok

      _ ->
        Hive.Jobs.complete(state.job_id)
        Hive.Jobs.unblock_dependents(state.job_id)
    end

    Hive.Telemetry.emit([:hive, :bee, :completed], %{}, %{
      bee_id: state.bee_id,
      job_id: state.job_id
    })

    record_costs_from_events(state)

    # Collect phase output if this is a phase job
    job = case Hive.Jobs.get(state.job_id) do
      {:ok, j} -> j
      _ -> nil
    end

    is_phase_job = job && Map.get(job, :phase_job, false)

    if is_phase_job do
      collect_phase_output(state, job)
    else
      record_files_changed(state)
    end

    is_scout = job && Map.get(job, :scout, false)
    skip_verification = job && Map.get(job, :skip_verification, false)

    cond do
      is_scout ->
        # Scout jobs: waggle Queen with scout_complete and the raw output
        output = IO.iodata_to_binary(state.output)
        parent_job_id = Map.get(job, :scout_for)

        body = Jason.encode!(%{
          scout_job_id: state.job_id,
          parent_job_id: parent_job_id,
          output: output
        })

        Hive.Waggle.send(state.bee_id, "queen", "scout_complete", body)

      is_phase_job ->
        # Phase jobs waggle Queen directly — no verification/merge needed
        session_id = Hive.Runtime.Models.extract_session_id(Enum.reverse(state.parsed_events))
        body = "Job #{state.job_id} completed successfully (phase: #{job.phase})"
        body = if session_id, do: body <> "\nSession ID: #{session_id}", else: body
        Hive.Waggle.send(state.bee_id, "queen", "job_complete", body)

      skip_verification ->
        # Simple jobs skip drone verification, go straight to Queen
        Hive.Waggle.send(state.bee_id, "queen", "job_complete",
          "Job #{state.job_id} completed (skip_verification)")

      true ->
        # Standard jobs: broadcast to Drone for independent verification.
        # The Drone verifies, then forwards to MergeQueue on pass.
        # Do NOT waggle Queen here — the MergeQueue will waggle "job_merged" after merge.
        Phoenix.PubSub.broadcast(
          Hive.PubSub,
          "drone:review",
          {:review_job, state.job_id, state.bee_id, state.cell_id}
        )
    end

    Hive.Progress.clear(state.bee_id)
  end

  defp collect_phase_output(state, job) do
    raw_output = IO.iodata_to_binary(state.output)
    events = Enum.reverse(state.parsed_events)

    case Hive.Queen.PhaseCollector.collect(job.phase, raw_output, events) do
      {:ok, artifact} ->
        Hive.Quests.store_artifact(job.quest_id, job.phase, artifact)

      {:error, reason} ->
        Logger.warning("Phase output parse failed for #{job.phase}: #{inspect(reason)}, storing raw output as fallback")
        fallback_artifact = %{
          "raw_output" => String.slice(raw_output, 0, 50_000),
          "parse_failed" => true,
          "parse_error" => inspect(reason)
        }
        Hive.Quests.store_artifact(job.quest_id, job.phase, fallback_artifact)
    end
  rescue
    e ->
      Logger.warning("Phase output collection error: #{inspect(e)}, storing minimal fallback")
      raw_output = IO.iodata_to_binary(state.output)
      fallback_artifact = %{
        "raw_output" => String.slice(raw_output, 0, 50_000),
        "parse_failed" => true,
        "parse_error" => inspect(e)
      }
      Hive.Quests.store_artifact(job.quest_id, job.phase, fallback_artifact)
  end

  defp record_files_changed(state) do
    case Store.get(:cells, state.cell_id) do
      %{worktree_path: path} when is_binary(path) ->
        case Hive.Git.safe_cmd( ["diff", "--name-only", "HEAD~1..HEAD"],
               cd: path, stderr_to_stdout: true) do
          {output, 0} ->
            files = String.split(output, "\n", trim: true)

            case Hive.Jobs.get(state.job_id) do
              {:ok, job} ->
                Store.put(:jobs, Map.merge(job, %{
                  files_changed: length(files),
                  changed_files: files
                }))

              _ ->
                :ok
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.debug("Failed to record files changed: #{inspect(e)}")
      :ok
  end

  defp mark_failed(state, reason) do
    update_bee_status(state.bee_id, "crashed")
    Hive.Jobs.fail(state.job_id)

    Hive.Telemetry.emit([:hive, :bee, :failed], %{}, %{
      bee_id: state.bee_id,
      error: reason
    })

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
    |> Enum.reverse()
    |> Hive.Runtime.Models.extract_costs()
    |> Enum.each(fn cost_data ->
      Hive.Costs.record(state.bee_id, cost_data)
    end)
  end

  defp maybe_ensure_agent(state, cell) do
    case Hive.Jobs.get(state.job_id) do
      {:ok, job} ->
        # Standard comb-level agent
        case Store.get(:combs, cell.comb_id) do
          nil ->
            :ok

          comb when comb.path != nil ->
            Hive.AgentProfile.ensure_agent(comb.path, %{
              title: job.title,
              description: job.description
            })

            Hive.AgentProfile.install_agents(comb.path, cell.worktree_path)
            :ok

          _comb ->
            :ok
        end

      {:error, _} ->
        :ok
    end
  end

  defp update_progress(bee_id, events) do
    Hive.Runtime.Models.progress_from_events(events)
    |> Enum.each(fn progress ->
      Hive.Progress.update(bee_id, progress)
    end)
  rescue
    e ->
      Logger.debug("Progress update failed for bee #{bee_id}: #{inspect(e)}")
      :ok
  end

  defp track_context_usage(bee_id, events) do
    # Extract token usage from events
    costs = Hive.Runtime.Models.extract_costs(events)

    Enum.each(costs, fn cost ->
      input = cost["input_tokens"] || cost[:input_tokens] || 0
      output = cost["output_tokens"] || cost[:output_tokens] || 0

      if input > 0 or output > 0 do
        case Hive.Runtime.ContextMonitor.record_usage(bee_id, input, output) do
          {:ok, :handoff_needed} ->
            Logger.warning("Bee #{bee_id} needs handoff - context at critical level, triggering")
            send(self(), :context_handoff)

          {:ok, :critical} ->
            Logger.warning("Bee #{bee_id} context usage critical, triggering handoff")
            send(self(), :context_handoff)

          {:ok, :warning} ->
            Logger.info("Bee #{bee_id} context usage warning")

          _ ->
            :ok
        end
      end
    end)
  rescue
    error ->
      Logger.debug("Failed to track context usage for bee #{bee_id}: #{inspect(error)}")
      :ok
  end

  defp maybe_fallback_model(state) do
    # Only try fallback once (check if we already fell back)
    if Map.get(state, :fallback_attempted) do
      :no_fallback
    else
      current_model =
        case Store.get(:bees, state.bee_id) do
          %{assigned_model: m} when is_binary(m) -> m
          _ -> nil
        end

      fallback = if current_model, do: Hive.Runtime.ModelResolver.fallback(current_model)

      if fallback do
        # Update bee record with fallback model
        case Store.get(:bees, state.bee_id) do
          nil -> :no_fallback
          bee -> Store.put(:bees, %{bee | assigned_model: fallback})
        end

        # Re-spawn the API task with fallback model
        case Store.get(:cells, state.cell_id) do
          %{worktree_path: path} ->
            prompt = build_prompt(state)
            task = Task.async(fn ->
              Hive.Runtime.AgentLoop.run(prompt, path,
                model: fallback,
                tool_set: :standard,
                include_dynamic: true
              )
            end)
            {:ok, task, fallback}

          _ ->
            :no_fallback
        end
      else
        :no_fallback
      end
    end
  rescue
    e ->
      Logger.debug("Model fallback failed: #{inspect(e)}")
      :no_fallback
  end

  defp do_stop(state) do
    if state.task != nil do
      Task.shutdown(state.task, 5_000)
    end

    if state.port != nil and port_alive?(state.port) do
      Port.close(state.port)
    end

    update_bee_status(state.bee_id, "stopped")
    %{state | status: :done, port: nil, task: nil}
  rescue
    ArgumentError -> %{state | status: :done, port: nil, task: nil}
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

  defp schedule_checkpoint do
    Process.send_after(self(), :checkpoint, 30_000)
  end

  defp build_checkpoint_data(state) do
    events = Enum.reverse(state.parsed_events)

    tool_calls =
      Enum.count(events, fn e ->
        Map.get(e, :type) in [:tool_call, "tool_call", :tool_use, "tool_use"]
      end)

    files_modified =
      events
      |> Enum.flat_map(fn e ->
        args = Map.get(e, :args, %{})
        [Map.get(args, "file_path"), Map.get(args, "path")]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    iteration =
      events
      |> Enum.count(&(Map.get(&1, :type) in [:iteration, "iteration"]))

    error_count =
      events
      |> Enum.count(&(Map.get(&1, :type) in [:error, "error"]))

    phase =
      case Hive.Jobs.get(state.job_id) do
        {:ok, %{phase: p}} when is_binary(p) -> p
        _ -> "working"
      end

    %{
      phase: phase,
      tool_calls: tool_calls,
      files_modified: files_modified,
      iteration: iteration,
      error_count: error_count,
      progress_summary: "Bee running: #{tool_calls} tool calls, #{iteration} iterations",
      pending_work: "Continuing job #{state.job_id}"
    }
  end

  defp via(bee_id) do
    {:via, Registry, {@registry, {:bee, bee_id}}}
  end

  # -- Private: pre-dispatch instructions -------------------------------------

  @doc false
  defp write_pre_dispatch(worktree_path, job_id) do
    case Hive.Jobs.get(job_id) do
      {:ok, job} ->
        content = build_instructions_content(job)
        instructions_path = Path.join([worktree_path, ".claude", "instructions.md"])
        File.mkdir_p!(Path.dirname(instructions_path))
        File.write!(instructions_path, content)
        Logger.debug("Pre-dispatch instructions written for job #{job_id}")

      {:error, _} ->
        :ok
    end
  rescue
    e ->
      Logger.debug("Pre-dispatch write failed (non-fatal): #{inspect(e)}")
      :ok
  end

  defp build_instructions_content(job) do
    sections = [
      "# Job Instructions\n",
      "## #{job.title}\n"
    ]

    sections =
      if job.description && job.description != "" do
        sections ++ ["### Description\n\n#{job.description}\n"]
      else
        sections
      end

    sections =
      case Map.get(job, :scout_findings) do
        findings when is_binary(findings) and findings != "" ->
          sections ++ ["### Scout Findings\n\n#{findings}\n"]

        _ ->
          sections
      end

    sections =
      case Map.get(job, :acceptance_criteria) do
        criteria when is_binary(criteria) and criteria != "" ->
          sections ++ ["### Acceptance Criteria\n\n#{criteria}\n"]

        _ ->
          sections
      end

    sections =
      case Map.get(job, :target_files) do
        files when is_list(files) and files != [] ->
          file_list = Enum.map_join(files, "\n", &"- `#{&1}`")
          sections ++ ["### Target Files\n\n#{file_list}\n"]

        _ ->
          sections
      end

    Enum.join(sections, "\n")
  end

  # -- Private: spawn rollback ------------------------------------------------

  defp rollback_cell(cell_id) do
    Hive.Cell.remove(cell_id, force: true)
  rescue
    e ->
      Logger.debug("Cell rollback failed for #{cell_id}: #{inspect(e)}")
      :ok
  end

  defp rollback_cell_for_bee(bee_id) do
    case Store.find_one(:cells, fn c -> c.bee_id == bee_id and c.status == "active" end) do
      nil -> :ok
      cell -> rollback_cell(cell.id)
    end
  rescue
    _ -> :ok
  end
end
