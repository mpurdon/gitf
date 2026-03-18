defmodule GiTF.Ghost.Worker do
  @moduledoc """
  GenServer managing a single ghost's lifecycle.

  Each ghost is a Claude Code agent working on one op within a sector.
  The Worker provisions an isolated worktree (shell), spawns Claude
  headless with the op prompt, and reports results back to the Major
  via link_msg messages.

  ## Lifecycle

      start_link -> init -> {:continue, :provision}
                          -> create shell
                          -> update DB record
                          -> generate settings
                          -> spawn Claude headless
                          -> accumulate port output
                          -> exit_status 0 -> success -> link_msg queen
                          -> exit_status N -> failure -> link_msg queen

  ## Registration

  Workers register via `GiTF.Registry` under `{:ghost, ghost_id}` for
  easy lookup and to prevent duplicate workers for the same ghost.

  ## Restart strategy

  Workers use `restart: :temporary` because the Major decides whether
  and how to retry failed ghosts -- not the supervisor.
  """

  use GenServer
  require Logger

  alias GiTF.Archive

  @registry GiTF.Registry

  # -- Types -------------------------------------------------------------------

  @type state :: %{
          ghost_id: String.t(),
          op_id: String.t(),
          sector_id: String.t(),
          shell_id: String.t() | nil,
          port: port() | nil,
          task: Task.t() | nil,
          execution_mode: :api | :cli | :ollama | :bedrock,
          status: :provisioning | :running | :done | :failed,
          gitf_root: String.t(),
          output: iodata(),
          parsed_events: [map()]
        }

  # -- Child spec --------------------------------------------------------------

  def child_spec(opts) do
    ghost_id = Keyword.fetch!(opts, :ghost_id)

    %{
      id: {__MODULE__, ghost_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  # -- Client API --------------------------------------------------------------

  @doc """
  Starts a Ghost Worker process.

  ## Required options

    * `:ghost_id` - the ghost's database ID
    * `:op_id` - the op being worked on
    * `:sector_id` - the sector (repository) to work in
    * `:gitf_root` - the gitf workspace root directory

  ## Optional

    * `:prompt` - explicit prompt text (overrides op title/description)
    * `:claude_executable` - path to the executable to spawn (for testing)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    ghost_id = Keyword.fetch!(opts, :ghost_id)
    name = via(ghost_id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the current status of a ghost worker by ghost_id."
  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(ghost_id) do
    case lookup(ghost_id) do
      {:ok, pid} -> {:ok, GenServer.call(pid, :status)}
      :error -> {:error, :not_found}
    end
  end

  @doc "Gracefully stops a ghost worker."
  @spec stop(String.t()) :: :ok | {:error, :not_found}
  def stop(ghost_id) do
    case lookup(ghost_id) do
      {:ok, pid} -> GenServer.call(pid, :stop)
      :error -> {:error, :not_found}
    end
  end

  @doc "Looks up a ghost worker PID via the Registry."
  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(ghost_id) do
    case Registry.lookup(@registry, {:ghost, ghost_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  # -- GenServer callbacks -----------------------------------------------------

  @impl true
  def init(opts) do
    ghost_id = Keyword.fetch!(opts, :ghost_id)
    op_id = Keyword.fetch!(opts, :op_id)
    sector_id = Keyword.fetch!(opts, :sector_id)
    gitf_root = Keyword.fetch!(opts, :gitf_root)

    # Set correlation IDs for structured logging
    GiTF.Logger.set_bee_context(ghost_id, op_id)

    state = %{
      ghost_id: ghost_id,
      op_id: op_id,
      sector_id: sector_id,
      shell_id: nil,
      port: nil,
      task: nil,
      execution_mode: GiTF.Runtime.ModelResolver.execution_mode(),
      status: :provisioning,
      gitf_root: gitf_root,
      output: [],
      parsed_events: [],
      opts: opts,
      backup_timer: schedule_checkpoint()
    }

    {:ok, state, {:continue, :provision}}
  end

  @impl true
  def handle_continue(:provision, state) do
    case provision(state) do
      {:ok, updated_state} ->
        {:noreply, updated_state}

      {:error, {step, reason}} ->
        Logger.error("Ghost #{state.ghost_id} failed to provision at step #{step}: #{inspect(reason)}")
        GiTF.Telemetry.emit([:gitf, :ghost, :provision_failed], %{}, %{
          ghost_id: state.ghost_id,
          op_id: state.op_id,
          step: step,
          reason: inspect(reason)
        })
        mark_failed(state, "Provision failed at #{step}: #{inspect(reason)}")
        {:stop, :normal, %{state | status: :failed}}

      {:error, reason} ->
        Logger.error("Ghost #{state.ghost_id} failed to provision: #{inspect(reason)}")
        GiTF.Telemetry.emit([:gitf, :ghost, :provision_failed], %{}, %{
          ghost_id: state.ghost_id,
          op_id: state.op_id,
          reason: inspect(reason)
        })
        mark_failed(state, "Provision failed: #{inspect(reason)}")
        {:stop, :normal, %{state | status: :failed}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      ghost_id: state.ghost_id,
      op_id: state.op_id,
      sector_id: state.sector_id,
      shell_id: state.shell_id,
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
    events = GiTF.Runtime.Models.parse_output(data)
    update_progress(state.ghost_id, events)
    
    # Track context usage from events
    track_context_usage(state.ghost_id, events)

    {:noreply,
     %{state | output: [state.output, data], parsed_events: Enum.reverse(events) ++ state.parsed_events}}
  end

  def handle_info({port, {:exit_status, 0}}, %{port: port} = state) do
    Logger.info("Ghost #{state.ghost_id} completed successfully")
    mark_success(state)
    {:stop, :normal, %{state | status: :done, port: nil}}
  end

  def handle_info({port, {:exit_status, exit_code}}, %{port: port} = state) do
    Logger.warning("Ghost #{state.ghost_id} exited with status #{exit_code}")
    output = IO.iodata_to_binary(state.output)
    mark_failed(state, "Exit code #{exit_code}: #{String.slice(output, 0, 500)}")
    {:stop, :normal, %{state | status: :failed, port: nil}}
  end

  # -- API mode: Task completion -----------------------------------------------

  def handle_info({ref, {:ok, result}}, %{task: %Task{ref: ref}} = state) do
    # Task completed successfully — treat like exit_status 0
    Process.demonitor(ref, [:flush])
    Logger.info("Ghost #{state.ghost_id} API task completed successfully")

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
    Logger.warning("Ghost #{state.ghost_id} API task failed: #{inspect(reason)}")

    # Try model fallback before giving up
    case maybe_fallback_model(state) do
      {:ok, new_task, fallback_model} ->
        Logger.info("Ghost #{state.ghost_id} falling back to model #{fallback_model}")
        {:noreply, %{state | task: new_task, fallback_attempted: true}}

      :no_fallback ->
        # Record API failure in circuit breaker so global outage is detected
        GiTF.CircuitBreaker.call("api:llm", fn -> {:error, reason} end)
        mark_failed(state, "API error: #{inspect(reason)}")
        {:stop, :normal, %{state | status: :failed, task: nil}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    # Task process crashed
    Logger.error("Ghost #{state.ghost_id} API task crashed: #{inspect(reason)}")
    mark_failed(state, "Task crash: #{inspect(reason)}")
    {:stop, :normal, %{state | status: :failed, task: nil}}
  end

  def handle_info({:agent_progress, ghost_id, event}, state) when ghost_id == state.ghost_id do
    progress = format_agent_progress(event)
    GiTF.Progress.update(state.ghost_id, progress)
    {:noreply, state}
  end

  def handle_info(:backup, state) do
    if state.status == :running do
      backup_data = build_checkpoint_data(state)
      GiTF.Backup.save(state.ghost_id, backup_data)
    end

    {:noreply, %{state | backup_timer: schedule_checkpoint()}}
  end

  def handle_info(:context_handoff, %{status: :running} = state) do
    Logger.info("Ghost #{state.ghost_id} initiating proactive context transfer")

    # Create transfer with current state
    GiTF.Transfer.create(state.ghost_id)

    # Stop the current process (port/task)
    state = do_stop(state)

    # Reset the op to pending so it can be re-spawned with transfer context
    case GiTF.Ops.get(state.op_id) do
      {:ok, op} ->
        Archive.put(:ops, %{op | status: "pending"})
      _ ->
        :ok
    end

    # Notify Major that ghost handed off — Major's op spawner will pick it up
    GiTF.Link.send(
      state.ghost_id,
      "major",
      "context_handoff",
      "Ghost #{state.ghost_id} handed off op #{state.op_id} due to context exhaustion"
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
        Logger.warning("Beacon check failed: ghost #{state.ghost_id} process is dead after 10s")
        mark_failed(state, "Process died within 10 seconds of spawning")
        {:stop, :normal, %{state | status: :failed}}

      not has_output? ->
        Logger.warning("Beacon check: ghost #{state.ghost_id} alive but no output after 10s")
        # Process is alive but silent -- not fatal, just log a warning
        {:noreply, state}

      true ->
        Logger.debug("Beacon check passed for ghost #{state.ghost_id}")
        {:noreply, state}
    end
  end

  def handle_info(:verify_beacon, state) do
    # Ghost is no longer running (already completed or failed), ignore
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Ghost #{state.ghost_id} received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # If ghost was actively running, preserve context via backup + transfer
    if state.status == :running do
      try do
        # Save final backup so transfer has latest progress
        backup_data = build_checkpoint_data(state)
        GiTF.Backup.save(state.ghost_id, backup_data)

        # Create transfer so replacement ghost has context
        GiTF.Transfer.create(state.ghost_id)
        Logger.info("Ghost #{state.ghost_id} crash transfer saved")
      rescue
        e ->
          Logger.debug("Crash transfer failed for ghost #{state.ghost_id}: #{inspect(e)}")
      end
    end

    # Mark ghost as crashed if still in an active state
    if state.status in [:provisioning, :running] do
      update_ghost_status(state.ghost_id, "crashed")
    end

    # Exfil API task if running (allow 2s for graceful cleanup)
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
    case GiTF.RateLimiter.acquire(GiTF.RateLimiter) do
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
    # Enrich logging metadata with mission_id
    is_phase_job =
      case GiTF.Ops.get(state.op_id) do
        {:ok, op} ->
          GiTF.Logger.set_bee_context(state.ghost_id, state.op_id, op.mission_id)
          Map.get(op, :phase_job, false)

        _ ->
          false
      end

    with {:shell, {:ok, shell}} <- {:shell, create_shell(state)},
         {:update, :ok} <- {:update, update_bee_working(state, shell)},
         {:transition, :ok} <- {:transition, maybe_transition_job(state)},
         {:agent, :ok} <- {:agent, maybe_ensure_agent(state, shell)} do
      # Apply role-based tool restrictions via settings.local.json
      role = role_for_job(state.op_id)
      GiTF.Runtime.Settings.generate_role_settings(role, shell.worktree_path)

      # Pre-dispatch: write op instructions so Claude Code has context at boot
      write_pre_dispatch(shell.worktree_path, state.op_id)

      # Build task-specific skill for non-phase ops (works for both API and CLI)
      unless is_phase_job do
        maybe_build_task_skill(build_prompt(state), shell.worktree_path, state.op_id)
      end

      # API mode spawns Task.async directly (no timeout wrapper needed —
      # the task runs asynchronously). CLI mode uses spawn_process_with_timeout
      # to handle executable lookup and port creation with a timeout.
      spawn_result =
        if state.execution_mode in [:api, :ollama, :bedrock] do
          spawn_process(state, shell)
        else
          spawn_process_with_timeout(state, shell)
        end

      case spawn_result do
        {:ok, handle} ->
          # Schedule beacon verification to confirm the process actually started
          Process.send_after(self(), :verify_beacon, 10_000)

          if is_struct(handle, Task) do
            {:ok, %{state | shell_id: shell.id, task: handle, status: :running}}
          else
            {:ok, %{state | shell_id: shell.id, port: handle, status: :running}}
          end

        {:error, reason} ->
          # Rollback: clean up the shell/worktree on spawn failure
          Logger.warning("Spawn failed for ghost #{state.ghost_id}, rolling back shell #{shell.id}")
          rollback_cell(shell.id)
          {:error, reason}
      end
    else
      {step, {:error, reason}} ->
        # If shell was created but a later step failed, attempt cleanup.
        # We check whether shell_id is set by looking at state -- if create_shell
        # succeeded but a subsequent step failed, the shell variable is not in scope
        # here, so we look it up by ghost_id.
        rollback_cell_for_bee(state.ghost_id)
        {:error, {step, reason}}
    end
  end

  defp provision_revive(state) do
    shell_id = Keyword.fetch!(state.opts, :shell_id)

    with {:ok, shell} <- GiTF.Shell.get(shell_id),
         :ok <- update_bee_working(state, shell),
         {:ok, handle} <- spawn_process(state, shell) do
      if is_struct(handle, Task) do
        {:ok, %{state | shell_id: shell.id, task: handle, status: :running}}
      else
        {:ok, %{state | shell_id: shell.id, port: handle, status: :running}}
      end
    end
  end

  defp create_shell(state) do
    GiTF.Shell.create(state.sector_id, state.ghost_id, gitf_root: state.gitf_root)
  end

  defp role_for_job(op_id) do
    case GiTF.Ops.get(op_id) do
      {:ok, %{recon: true}} -> :recon
      _ -> :builder
    end
  end

  defp update_bee_working(state, shell) do
    case Archive.get(:ghosts, state.ghost_id) do
      nil ->
        {:error, :bee_not_found}

      ghost ->
        updated =
          Map.merge(ghost, %{status: "working", shell_path: shell.worktree_path, pid: inspect(self())})

        Archive.put(:ghosts, updated)
        :ok
    end
  end

  defp maybe_transition_job(state) do
    case GiTF.Ops.get(state.op_id) do
      {:ok, %{status: "assigned"}} ->
        case GiTF.Ops.start(state.op_id) do
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

  defp spawn_process_with_timeout(state, shell) do
    caller = self()

    # Run spawn in a monitored process so we can enforce a timeout,
    # but transfer port ownership back to the caller (Worker GenServer)
    # before the spawner exits.
    {pid, ref} =
      spawn_monitor(fn ->
        result = spawn_process(state, shell)

        case result do
          {:ok, port} when is_port(port) ->
            # Transfer port ownership to the Worker before exiting.
            # Port.connect also unlinks the port from this process.
            Port.connect(port, caller)
            send(caller, {:spawn_result, self(), {:ok, port}})

          other ->
            send(caller, {:spawn_result, self(), other})
        end
      end)

    receive do
      {:spawn_result, ^pid, result} ->
        # Clean up the monitor
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:spawn_crash, reason}}
    after
      @spawn_timeout_ms ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)
        Logger.error("Ghost #{state.ghost_id} spawn timed out after #{@spawn_timeout_ms}ms")
        {:error, :spawn_timeout}
    end
  end

  defp spawn_process(state, shell) do
    prompt = build_prompt(state)
    executable = Keyword.get(state.opts, :claude_executable)

    # Get the assigned model from the ghost record
    model =
      case Archive.get(:ghosts, state.ghost_id) do
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
        spawn_api_task(prompt, shell.worktree_path, spawn_opts, state)

      nil ->
        # CLI mode: settings are generated during shell creation (GiTF.Shell.create/3)
        GiTF.Runtime.Models.spawn_headless(prompt, shell.worktree_path, spawn_opts)

      exe_path ->
        # Testing path: use provided executable instead of Claude
        spawn_test_executable(exe_path, prompt, shell)
    end
  end

  defp spawn_api_task(prompt, working_dir, spawn_opts, state) do
    ghost_id = state.ghost_id

    # Determine tool_set based on phase op type
    tool_set =
      case GiTF.Ops.get(state.op_id) do
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
        send(self(), {:agent_progress, ghost_id, event})
      end)

    task = Task.async(fn ->
      GiTF.Runtime.AgentLoop.run(prompt, working_dir, agent_opts)
    end)

    {:ok, task}
  end

  defp maybe_build_task_skill(_prompt, working_dir, op_id) do
    skill_path = Path.join([working_dir, ".claude", "agents", "task-skill.md"])

    # Check if a recent skill file already exists (skip regeneration on retries)
    if task_skill_fresh?(skill_path) do
      Logger.debug("Task skill already exists and is fresh for op #{op_id}, skipping")
      :ok
    else
      job_info =
        case GiTF.Ops.get(op_id) do
          {:ok, op} -> op
          _ -> nil
        end

      if is_nil(job_info) do
        :ok
      else
        do_build_task_skill(job_info, working_dir, op_id)
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

  defp do_build_task_skill(job_info, working_dir, op_id) do
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

    case GiTF.Runtime.Models.generate_text(research_prompt, model: "haiku", max_tokens: 1024) do
      {:ok, skill_content} when is_binary(skill_content) and skill_content != "" ->
        agents_dir = Path.join([working_dir, ".claude", "agents"])
        File.mkdir_p!(agents_dir)
        skill_path = Path.join(agents_dir, "task-skill.md")
        File.write!(skill_path, skill_content)
        Logger.info("Built task skill for op #{op_id}")

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.debug("Task skill research failed (non-fatal): #{inspect(e)}")
      :ok
  end

  defp spawn_test_executable(exe_path, prompt, shell) do
    port =
      Port.open({:spawn_executable, exe_path}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: [prompt],
        cd: shell.worktree_path
      ])

    {:ok, port}
  end

  defp build_prompt(state) do
    case Keyword.get(state.opts, :prompt) do
      nil ->
        case GiTF.Ops.get(state.op_id) do
          {:ok, op} ->
            if op.description do
              "#{op.title}\n\n#{op.description}"
            else
              op.title
            end

          {:error, _} ->
            "Work on op #{state.op_id}"
        end

      prompt ->
        prompt
    end
  end

  # -- Private: completion handling --------------------------------------------

  defp mark_success(state) do
    update_ghost_status(state.ghost_id, "stopped")

    case GiTF.Ops.get(state.op_id) do
      {:ok, %{status: "done"}} ->
        :ok

      _ ->
        GiTF.Ops.complete(state.op_id)
        GiTF.Ops.unblock_dependents(state.op_id)
    end

    GiTF.Telemetry.emit([:gitf, :ghost, :completed], %{}, %{
      ghost_id: state.ghost_id,
      op_id: state.op_id
    })

    record_costs_from_events(state)

    # Collect phase output if this is a phase op
    op = case GiTF.Ops.get(state.op_id) do
      {:ok, j} -> j
      _ -> nil
    end

    is_phase_job = op && Map.get(op, :phase_job, false)

    if is_phase_job do
      collect_phase_output(state, op)
    else
      record_files_changed(state)
    end

    is_scout = op && Map.get(op, :recon, false)
    skip_verification = op && Map.get(op, :skip_verification, false)

    cond do
      is_scout ->
        # Recon ops: link_msg Major with scout_complete and the raw output
        output = IO.iodata_to_binary(state.output)
        parent_op_id = Map.get(op, :scout_for)

        body = Jason.encode!(%{
          scout_op_id: state.op_id,
          parent_op_id: parent_op_id,
          output: output
        })

        GiTF.Link.send(state.ghost_id, "major", "scout_complete", body)

      is_phase_job ->
        # Phase ops link_msg Major directly — no verification/sync needed
        session_id = GiTF.Runtime.Models.extract_session_id(Enum.reverse(state.parsed_events))
        body = "Job #{state.op_id} completed successfully (phase: #{op.phase})"
        body = if session_id, do: body <> "\nSession ID: #{session_id}", else: body
        GiTF.Link.send(state.ghost_id, "major", "job_complete", body)

      skip_verification ->
        # Simple ops skip tachikoma verification, go straight to Major
        GiTF.Link.send(state.ghost_id, "major", "job_complete",
          "Job #{state.op_id} completed (skip_verification)")

      true ->
        # Standard ops: broadcast to Tachikoma for independent verification.
        # The Tachikoma verifies, then forwards to SyncQueue on pass.
        # Do NOT link_msg Major here — the SyncQueue will link_msg "job_merged" after sync.
        Phoenix.PubSub.broadcast(
          GiTF.PubSub,
          "tachikoma:review",
          {:review_job, state.op_id, state.ghost_id, state.shell_id}
        )
    end

    GiTF.Progress.clear(state.ghost_id)
  end

  defp collect_phase_output(state, op) do
    raw_output = IO.iodata_to_binary(state.output)
    events = Enum.reverse(state.parsed_events)

    case GiTF.Major.PhaseCollector.collect(op.phase, raw_output, events) do
      {:ok, artifact} ->
        GiTF.Missions.store_artifact(op.mission_id, op.phase, artifact)

      {:error, reason} ->
        Logger.warning("Phase output parse failed for #{op.phase}: #{inspect(reason)}, storing raw output as fallback")
        fallback_artifact = %{
          "raw_output" => String.slice(raw_output, 0, 50_000),
          "parse_failed" => true,
          "parse_error" => inspect(reason)
        }
        GiTF.Missions.store_artifact(op.mission_id, op.phase, fallback_artifact)
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
      GiTF.Missions.store_artifact(op.mission_id, op.phase, fallback_artifact)
  end

  defp record_files_changed(state) do
    case Archive.get(:shells, state.shell_id) do
      %{worktree_path: path} when is_binary(path) ->
        case GiTF.Git.safe_cmd( ["diff", "--name-only", "HEAD~1..HEAD"],
               cd: path, stderr_to_stdout: true) do
          {output, 0} ->
            files = String.split(output, "\n", trim: true)

            case GiTF.Ops.get(state.op_id) do
              {:ok, op} ->
                Archive.put(:ops, Map.merge(op, %{
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
    update_ghost_status(state.ghost_id, "crashed")
    GiTF.Ops.fail(state.op_id)

    GiTF.Telemetry.emit([:gitf, :ghost, :failed], %{}, %{
      ghost_id: state.ghost_id,
      error: reason
    })

    record_costs_from_events(state)
    GiTF.Progress.clear(state.ghost_id)

    GiTF.Link.send(
      state.ghost_id,
      "major",
      "job_failed",
      "Job #{state.op_id} failed: #{reason}"
    )
  end

  defp record_costs_from_events(state) do
    state.parsed_events
    |> Enum.reverse()
    |> GiTF.Runtime.Models.extract_costs()
    |> Enum.each(fn cost_data ->
      GiTF.Costs.record(state.ghost_id, cost_data)
    end)
  end

  defp maybe_ensure_agent(state, shell) do
    case GiTF.Ops.get(state.op_id) do
      {:ok, op} ->
        # Standard sector-level agent
        case Archive.get(:sectors, shell.sector_id) do
          nil ->
            :ok

          sector when sector.path != nil ->
            GiTF.AgentProfile.ensure_agent(sector.path, %{
              title: op.title,
              description: op.description
            })

            GiTF.AgentProfile.install_agents(sector.path, shell.worktree_path)
            :ok

          _sector ->
            :ok
        end

      {:error, _} ->
        :ok
    end
  end

  defp update_progress(ghost_id, events) do
    GiTF.Runtime.Models.progress_from_events(events)
    |> Enum.each(fn progress ->
      GiTF.Progress.update(ghost_id, progress)
    end)
  rescue
    e ->
      Logger.debug("Progress update failed for ghost #{ghost_id}: #{inspect(e)}")
      :ok
  end

  defp track_context_usage(ghost_id, events) do
    # Extract token usage from events
    costs = GiTF.Runtime.Models.extract_costs(events)

    Enum.each(costs, fn cost ->
      input = cost["input_tokens"] || cost[:input_tokens] || 0
      output = cost["output_tokens"] || cost[:output_tokens] || 0

      if input > 0 or output > 0 do
        case GiTF.Runtime.ContextMonitor.record_usage(ghost_id, input, output) do
          {:ok, :transfer_needed} ->
            Logger.warning("Ghost #{ghost_id} needs transfer - context at critical level, triggering")
            send(self(), :context_handoff)

          {:ok, :critical} ->
            Logger.warning("Ghost #{ghost_id} context usage critical, triggering transfer")
            send(self(), :context_handoff)

          {:ok, :warning} ->
            Logger.info("Ghost #{ghost_id} context usage warning")

          _ ->
            :ok
        end
      end
    end)
  rescue
    error ->
      Logger.debug("Failed to track context usage for ghost #{ghost_id}: #{inspect(error)}")
      :ok
  end

  defp maybe_fallback_model(state) do
    # Only try fallback once (check if we already fell back)
    if Map.get(state, :fallback_attempted) do
      :no_fallback
    else
      current_model =
        case Archive.get(:ghosts, state.ghost_id) do
          %{assigned_model: m} when is_binary(m) -> m
          _ -> nil
        end

      fallback = if current_model, do: GiTF.Runtime.ModelResolver.fallback(current_model)

      if fallback do
        # Update ghost record with fallback model
        case Archive.get(:ghosts, state.ghost_id) do
          nil -> :no_fallback
          ghost -> Archive.put(:ghosts, %{ghost | assigned_model: fallback})
        end

        # Re-spawn the API task with fallback model
        case Archive.get(:shells, state.shell_id) do
          %{worktree_path: path} ->
            prompt = build_prompt(state)
            task = Task.async(fn ->
              GiTF.Runtime.AgentLoop.run(prompt, path,
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

    update_ghost_status(state.ghost_id, "stopped")
    %{state | status: :done, port: nil, task: nil}
  rescue
    ArgumentError -> %{state | status: :done, port: nil, task: nil}
  end

  defp update_ghost_status(ghost_id, status) do
    case Archive.get(:ghosts, ghost_id) do
      nil -> :ok
      ghost -> Archive.put(:ghosts, %{ghost | status: status})
    end
  end

  defp port_alive?(port) do
    Port.info(port) != nil
  rescue
    ArgumentError -> false
  end

  defp schedule_checkpoint do
    Process.send_after(self(), :backup, 30_000)
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
      case GiTF.Ops.get(state.op_id) do
        {:ok, %{phase: p}} when is_binary(p) -> p
        _ -> "working"
      end

    %{
      phase: phase,
      tool_calls: tool_calls,
      files_modified: files_modified,
      iteration: iteration,
      error_count: error_count,
      progress_summary: "Ghost running: #{tool_calls} tool calls, #{iteration} iterations",
      pending_work: "Continuing op #{state.op_id}"
    }
  end

  defp via(ghost_id) do
    {:via, Registry, {@registry, {:ghost, ghost_id}}}
  end

  # -- Private: pre-dispatch instructions -------------------------------------

  @doc false
  defp write_pre_dispatch(worktree_path, op_id) do
    case GiTF.Ops.get(op_id) do
      {:ok, op} ->
        content = build_instructions_content(op)
        instructions_path = Path.join([worktree_path, ".claude", "instructions.md"])
        File.mkdir_p!(Path.dirname(instructions_path))
        File.write!(instructions_path, content)
        Logger.debug("Pre-dispatch instructions written for op #{op_id}")

      {:error, _} ->
        :ok
    end
  rescue
    e ->
      Logger.debug("Pre-dispatch write failed (non-fatal): #{inspect(e)}")
      :ok
  end

  defp build_instructions_content(op) do
    sections = [
      "# Job Instructions\n",
      "## #{op.title}\n"
    ]

    sections =
      if op.description && op.description != "" do
        sections ++ ["### Description\n\n#{op.description}\n"]
      else
        sections
      end

    sections =
      case Map.get(op, :scout_findings) do
        findings when is_binary(findings) and findings != "" ->
          sections ++ ["### Recon Findings\n\n#{findings}\n"]

        _ ->
          sections
      end

    sections =
      case Map.get(op, :acceptance_criteria) do
        criteria when is_binary(criteria) and criteria != "" ->
          sections ++ ["### Acceptance Criteria\n\n#{criteria}\n"]

        _ ->
          sections
      end

    sections =
      case Map.get(op, :target_files) do
        files when is_list(files) and files != [] ->
          file_list = Enum.map_join(files, "\n", &"- `#{&1}`")
          sections ++ ["### Target Files\n\n#{file_list}\n"]

        _ ->
          sections
      end

    Enum.join(sections, "\n")
  end

  # -- Private: spawn rollback ------------------------------------------------

  defp rollback_cell(shell_id) do
    GiTF.Shell.remove(shell_id, force: true)
  rescue
    e ->
      Logger.debug("Cell rollback failed for #{shell_id}: #{inspect(e)}")
      :ok
  end

  defp rollback_cell_for_bee(ghost_id) do
    case Archive.find_one(:shells, fn c -> c.ghost_id == ghost_id and c.status == "active" end) do
      nil -> :ok
      shell -> rollback_cell(shell.id)
    end
  rescue
    _ -> :ok
  end
end
