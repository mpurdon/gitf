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

  Workers use `restart: :transient` — they auto-restart on abnormal exit
  (e.g., code reload crash) but stay down on normal exit (success/graceful
  failure). On restart, the worker detects the "restarting" ghost status
  and resumes from the last checkpoint/transfer context.
  """

  use GenServer
  require Logger

  alias GiTF.Archive
  require GiTF.Ghost.Status, as: GhostStatus

  @registry GiTF.Registry

  # Transient LLM failures (empty response, thinking-only response, network
  # blips) often succeed on immediate retry with the same model. We retry in
  # place before falling back to a different provider — a fallback switch is
  # expensive (cold context, different capability profile) and often lands on
  # a less-available provider.
  @max_same_model_retries 2

  # -- Types -------------------------------------------------------------------

  @type handle :: {:task, Task.t()} | {:port, port()} | nil

  @type state :: %{
          ghost_id: String.t(),
          op_id: String.t(),
          sector_id: String.t(),
          shell_id: String.t() | nil,
          handle: handle(),
          os_pid: pos_integer() | nil,
          started_at: integer() | nil,
          execution_mode: :api | :cli | :ollama | :bedrock,
          status: :provisioning | :running | :retrying | :done | :failed,
          gitf_root: String.t(),
          output: iodata(),
          output_bytes: non_neg_integer(),
          parsed_events: [map()]
        }

  # Cap on retained ghost output. A runaway ghost can emit unbounded text;
  # we keep only the most recent bytes (which carry the verdict/tail the
  # pipeline actually parses). Slack avoids re-collapsing on every chunk.
  @output_cap_bytes 4_000_000
  @output_slack_bytes 1_000_000

  # Retain only the most recent parsed events (newest-first) so a long-running
  # ghost's event list can't grow the heap without bound. Recent events are
  # what cost/context tracking reads; older ones are already accounted for.
  @max_parsed_events 2_000

  # -- Child spec --------------------------------------------------------------

  def child_spec(opts) do
    ghost_id = Keyword.fetch!(opts, :ghost_id)

    %{
      id: {__MODULE__, ghost_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
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

  @doc """
  Returns the current status of a ghost worker by ghost_id.

  `timeout` defaults to 5 seconds but can be lengthened — the worker
  serialises `handle_continue(:provision, _)` (real git/shell work)
  ahead of handle_call replies, so a status query during provisioning
  may queue behind it.
  """
  @spec status(String.t(), timeout()) :: {:ok, map()} | {:error, :not_found}
  def status(ghost_id, timeout \\ 5_000) do
    case lookup(ghost_id) do
      {:ok, pid} -> {:ok, GenServer.call(pid, :status, timeout)}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Gracefully stops a ghost worker.

  `timeout` defaults to 5 seconds; bump it when the worker may still
  be provisioning a shell/worktree (see `status/2`).
  """
  @spec stop(String.t(), timeout()) :: :ok | {:error, :not_found}
  def stop(ghost_id, timeout \\ 5_000) do
    case lookup(ghost_id) do
      {:ok, pid} -> GenServer.call(pid, :stop, timeout)
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
    GiTF.Logger.set_ghost_context(ghost_id, op_id)

    state = %{
      ghost_id: ghost_id,
      op_id: op_id,
      sector_id: sector_id,
      shell_id: nil,
      handle: nil,
      os_pid: nil,
      started_at: nil,
      execution_mode: GiTF.Runtime.ModelResolver.execution_mode(),
      status: :provisioning,
      gitf_root: gitf_root,
      output: [],
      output_bytes: 0,
      parsed_events: [],
      opts: opts,
      backup_timer: schedule_checkpoint(),
      fallback_attempted: false,
      first_error: nil,
      same_model_retries: 0,
      last_activity_at: System.monotonic_time(:second)
    }

    {:ok, state, {:continue, :provision}}
  end

  @impl true
  def handle_continue(:provision, state) do
    # Rate-limit agent spawning WITHOUT blocking the mailbox: if the limiter
    # asks us to wait, reschedule provisioning via send_after rather than
    # Process.sleep, so a :stop during startup backoff is still processed.
    case GiTF.RateLimiter.acquire(GiTF.RateLimiter) do
      {:ok, delay_ms} when is_integer(delay_ms) and delay_ms > 0 ->
        Process.send_after(self(), :provision, delay_ms)
        {:noreply, state}

      _ ->
        do_provision(state)
    end
  end

  defp do_provision(state) do
    case provision(state) do
      {:ok, updated_state} ->
        {:noreply, updated_state}

      {:error, {step, reason}} ->
        Logger.error(
          "Ghost #{state.ghost_id} failed to provision at step #{step}: #{inspect(reason)}"
        )

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
  def handle_info({port, {:data, data}}, %{handle: {:port, port}} = state) do
    events = GiTF.Runtime.Models.parse_output(data)
    update_progress(state.ghost_id, events)

    # Track context usage from events
    track_context_usage(state.ghost_id, events)

    {output, output_bytes} = append_output(state.output, state.output_bytes, data)

    {:noreply,
     %{
       state
       | output: output,
         output_bytes: output_bytes,
         parsed_events: cap_events(events, state.parsed_events),
         last_activity_at: System.monotonic_time(:second)
     }}
  end

  def handle_info({port, {:exit_status, 0}}, %{handle: {:port, port}} = state) do
    Logger.info("Ghost #{state.ghost_id} completed successfully")

    try do
      mark_success(state)
    rescue
      e ->
        Logger.error("Ghost #{state.ghost_id} mark_success crashed: #{Exception.message(e)}")
        mark_failed(state, "Success handler crashed: #{Exception.message(e)}")
    end

    {:stop, :normal, %{state | status: :done, handle: nil}}
  end

  def handle_info({port, {:exit_status, exit_code}}, %{handle: {:port, port}} = state) do
    Logger.warning("Ghost #{state.ghost_id} exited with status #{exit_code}")
    output = IO.iodata_to_binary(state.output)
    mark_failed(state, "Exit code #{exit_code}: #{String.slice(output, 0, 500) |> :binary.copy()}")
    {:stop, :normal, %{state | status: :failed, handle: nil}}
  end

  # -- API mode: Task completion -----------------------------------------------

  def handle_info({ref, {:ok, result}}, %{handle: {:task, %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    Logger.info("Ghost #{state.ghost_id} API task completed successfully")

    events = Map.get(result, :events, [])
    text = Map.get(result, :text, "")
    usage = Map.get(result, :usage, %{})

    input_tokens = Map.get(usage, :input_tokens, 0)
    output_tokens = Map.get(usage, :output_tokens, 0)

    if input_tokens > 0 or output_tokens > 0 do
      track_context_usage(state.ghost_id, [%{"type" => "result", "usage" => usage}])
    end

    result_status = Map.get(result, :status)

    cond do
      # Guard: AgentLoop should catch this before it gets here, but defend
      # anyway — any success-path with empty text is unusable downstream
      # (phase artifacts need JSON; implementation needs tool output).
      String.trim(text) == "" ->
        Logger.warning(
          "Ghost #{state.ghost_id} completed with empty output " <>
            "(tokens: in=#{input_tokens} out=#{output_tokens}) — treating as failure"
        )

        mark_failed(
          state,
          "Empty response: tokens in=#{input_tokens} out=#{output_tokens}, no text produced"
        )

        {:stop, :normal, %{state | status: :failed, handle: nil}}

      # Guard: agent hit max iterations without finishing — work is incomplete
      result_status == :max_iterations ->
        Logger.warning(
          "Ghost #{state.ghost_id} hit max iterations — treating as failure for retry"
        )

        mark_failed(state, "Agent hit max iterations (work incomplete)")
        {:stop, :normal, %{state | status: :failed, handle: nil}}

      true ->
        {output, output_bytes} = append_output(state.output, state.output_bytes, text)

        state = %{
          state
          | parsed_events: cap_events(events, state.parsed_events),
            output: output,
            output_bytes: output_bytes,
            handle: nil
        }

        try do
          mark_success(state)
        rescue
          e ->
            Logger.error("Ghost #{state.ghost_id} mark_success crashed: #{Exception.message(e)}")
            mark_failed(state, "Success handler crashed: #{Exception.message(e)}")
        end

        {:stop, :normal, %{state | status: :done}}
    end
  end

  def handle_info({ref, {:error, reason}}, %{handle: {:task, %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    Logger.warning("Ghost #{state.ghost_id} API task failed: #{inspect(reason)}")

    cond do
      retry_same_model?(reason, state) ->
        backoff = same_model_backoff_ms(state.same_model_retries)

        Logger.info(
          "Ghost #{state.ghost_id} scheduling same-model retry " <>
            "(retry #{state.same_model_retries + 1}/#{@max_same_model_retries}) in #{backoff}ms after #{inspect(reason)}"
        )

        # Non-blocking backoff: schedule the respawn instead of Process.sleep so
        # the worker stays responsive to :stop and :verify_beacon during the
        # wait. Status :retrying parks the heartbeat (see the non-running
        # :verify_beacon clause); the respawn handler re-arms it.
        Process.send_after(self(), {:respawn_same_model, reason}, backoff)

        {:noreply,
         %{
           state
           | status: :retrying,
             handle: nil,
             same_model_retries: state.same_model_retries + 1,
             first_error: state.first_error || reason
         }}

      true ->
        fallback_or_fail(reason, state)
    end
  end

  def handle_info({:respawn_same_model, reason}, %{status: :retrying} = state) do
    case respawn_current_model(state) do
      {:ok, new_task} ->
        # Re-arm the heartbeat — it stopped rescheduling while status != :running.
        Process.send_after(self(), :verify_beacon, timeout_cfg(:heartbeat_interval_ms, 15_000))
        {:noreply, %{state | handle: {:task, new_task}, status: :running}}

      :error ->
        fallback_or_fail(reason, state)
    end
  end

  def handle_info({:respawn_same_model, _reason}, state) do
    # Status changed (stopped/failed) before the scheduled retry fired — ignore.
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{handle: {:task, %Task{ref: ref}}} = state
      ) do
    Logger.error("Ghost #{state.ghost_id} API task crashed: #{inspect(reason)}")
    mark_failed(state, "Task crash: #{inspect(reason)}")
    {:stop, :normal, %{state | status: :failed, handle: nil}}
  end

  # Heartbeats refresh liveness only; skipping Progress.update avoids fanning
  # out to ProgressLive, which rebuilds its assign (O(N) Ops.get) per broadcast.
  def handle_info({:agent_progress, ghost_id, %{type: :heartbeat}}, state)
      when ghost_id == state.ghost_id do
    {:noreply, %{state | last_activity_at: System.monotonic_time(:second)}}
  end

  def handle_info({:agent_progress, ghost_id, event}, state) when ghost_id == state.ghost_id do
    progress = format_agent_progress(event)
    GiTF.Progress.update(state.ghost_id, progress)

    # Track context from per-response usage events (input_tokens = actual window size)
    case event do
      %{type: :response_usage, input_tokens: input, output_tokens: output}
      when input > 0 or output > 0 ->
        GiTF.Runtime.ContextMonitor.record_usage(ghost_id, input, output)

      _ ->
        :ok
    end

    {:noreply, %{state | last_activity_at: System.monotonic_time(:second)}}
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

    # Reset the op to pending so it can be re-spawned with transfer context.
    # Uses Ops.reset which clears ghost_id and nudges the spawner.
    GiTF.Ops.reset(state.op_id)

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

  # Deferred provisioning retry — the spawn rate limiter asked us to back off.
  def handle_info(:provision, state), do: handle_continue(:provision, state)

  # Recurring heartbeat — checks process health and activity staleness.
  # Timeouts live in `config :gitf, :timeouts` (see config/config.exs) so ops
  # can tune them at runtime without editing source.
  def handle_info(:verify_beacon, %{status: :running} = state) do
    alive? = handle_alive?(state)
    now = System.monotonic_time(:second)
    idle_seconds = now - state.last_activity_at
    stale_threshold = timeout_cfg(:stale_threshold_seconds, 120)
    max_wallclock = timeout_cfg(:max_wallclock_seconds, 3_600)
    wall_seconds = now - (state.started_at || now)

    cond do
      not alive? ->
        Logger.warning("Ghost #{state.ghost_id}: process is dead")
        mark_failed(state, "Underlying process died")
        {:stop, :normal, %{state | status: :failed}}

      wall_seconds > max_wallclock ->
        Logger.warning(
          "Ghost #{state.ghost_id}: exceeded wall-clock cap (#{wall_seconds}s > #{max_wallclock}s), killing"
        )

        kill_handle(state)
        mark_failed(state, "Exceeded wall-clock cap of #{max_wallclock} seconds")
        {:stop, :normal, %{state | status: :failed}}

      idle_seconds > stale_threshold ->
        Logger.warning(
          "Ghost #{state.ghost_id}: no activity for #{idle_seconds}s (threshold: #{stale_threshold}s), killing"
        )

        kill_handle(state)
        mark_failed(state, "No activity for #{idle_seconds} seconds")
        {:stop, :normal, %{state | status: :failed}}

      true ->
        # Healthy — reschedule
        Process.send_after(self(), :verify_beacon, timeout_cfg(:heartbeat_interval_ms, 15_000))
        {:noreply, state}
    end
  end

  def handle_info(:verify_beacon, state) do
    # Ghost is no longer running (completed or failed), don't reschedule
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning(
      "Ghost #{state.ghost_id} received unexpected message: #{inspect(msg)}",
      ghost_id: state.ghost_id,
      op_id: state.op_id
    )

    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    shutdown_handle(state, 2_000)
    GiTF.Progress.clear(state.ghost_id)

    case classify_exit(reason) do
      :clean ->
        # Normal exit — success/failure already reported via mark_success/mark_failed
        :ok

      :crash ->
        # Unexpected crash (code reload, linked Task death, etc.)
        # Supervisor will restart us with :transient — save context for auto-resume
        if state.status in [:provisioning, :running] do
          # Record any tokens consumed BEFORE the crash so the budget
          # cap sees them. Without this, mark_success/mark_failed are
          # the only paths that bill — a thrashing ghost can spend $$
          # in restart loops while the cap sits at $0.
          record_partial_costs(state)
          save_crash_context(state)
          update_ghost_status(state.ghost_id, GhostStatus.restarting())

          Logger.info(
            "Ghost #{state.ghost_id} saving context for auto-resume (reason: #{inspect(reason)})"
          )
        end

      :shutdown ->
        # Application shutting down — no restart coming, fail the op
        if state.status in [:provisioning, :running] do
          GiTF.Telemetry.set_span_error("shutdown")
          GiTF.Telemetry.end_current_span()
          record_partial_costs(state)
          save_crash_context(state)
          update_ghost_status(state.ghost_id, GhostStatus.crashed())
          GiTF.Ops.fail(state.op_id)

          try do
            GiTF.Link.send(
              state.ghost_id,
              "major",
              "job_failed",
              "Job #{state.op_id} failed: application shutdown"
            )
          rescue
            _ -> :ok
          end
        end
    end

    :ok
  rescue
    e ->
      Logger.warning(
        "Ghost #{state.ghost_id} terminate handler failed: #{Exception.message(e)}",
        ghost_id: state.ghost_id,
        op_id: state.op_id
      )

      :ok
  end

  defp classify_exit(:normal), do: :clean
  defp classify_exit(:shutdown), do: :shutdown
  defp classify_exit({:shutdown, _}), do: :shutdown
  defp classify_exit(_), do: :crash

  defp shutdown_handle(state, timeout) do
    case state.handle do
      {:task, task} ->
        Task.shutdown(task, timeout)

      {:port, port} ->
        # Port.close alone does not kill an unresponsive OS process — signal
        # the real pid too so a graceful stop can't leak a running subprocess.
        os_pid = state.os_pid || GiTF.Runtime.OsProc.port_pid(port)
        GiTF.Runtime.OsProc.terminate_async(os_pid, [])

        try do
          if port_alive?(port), do: Port.close(port)
        rescue
          _ -> :ok
        end

      nil ->
        :ok
    end
  end

  defp handle_alive?(state) do
    case state.handle do
      {:task, task} -> Process.alive?(task.pid)
      {:port, port} -> port_alive?(port)
      nil -> false
    end
  end

  defp kill_handle(state) do
    case state.handle do
      {:task, task} ->
        Task.shutdown(task, :brutal_kill)

      {:port, port} ->
        # Port.close alone does NOT kill an OS process that isn't reading
        # stdin — it would keep running, holding the worktree and burning
        # API spend. Signal the real OS pid (SIGTERM→SIGKILL) first, then
        # close the port. Async so the worker's stop path isn't blocked on
        # the grace period.
        os_pid = state.os_pid || GiTF.Runtime.OsProc.port_pid(port)
        GiTF.Runtime.OsProc.terminate_async(os_pid, [])

        try do
          Port.close(port)
        rescue
          _ -> :ok
        end

      nil ->
        :ok
    end
  end

  # Append to the retained output buffer, keeping only the most recent
  # @output_cap_bytes. Slack avoids collapsing to a binary on every chunk:
  # we only truncate once accumulation exceeds cap + slack.
  defp append_output(output, output_bytes, data) do
    data_bytes = byte_size(IO.iodata_to_binary(data))
    combined = [output, data]
    total = output_bytes + data_bytes

    if total > @output_cap_bytes + @output_slack_bytes do
      bin = IO.iodata_to_binary(combined)
      kept = binary_part(bin, byte_size(bin) - @output_cap_bytes, @output_cap_bytes)
      {kept, @output_cap_bytes}
    else
      {combined, total}
    end
  end

  # Prepend new events (newest-first) and bound the retained list.
  defp cap_events(events, existing) do
    (Enum.reverse(events) ++ existing) |> Enum.take(@max_parsed_events)
  end

  defp save_crash_context(state) do
    try do
      backup_data = build_checkpoint_data(state)
      GiTF.Backup.save(state.ghost_id, backup_data)
      GiTF.Transfer.create(state.ghost_id)
    rescue
      e ->
        Logger.warning(
          "Crash context save failed for ghost #{state.ghost_id}: #{Exception.message(e)}",
          ghost_id: state.ghost_id,
          op_id: state.op_id
        )
    end
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
    cond do
      Keyword.get(state.opts, :revive, false) ->
        provision_revive(state)

      ghost_restarting?(state.ghost_id) ->
        Logger.info("Ghost #{state.ghost_id} auto-resuming after crash recovery")
        provision_auto_resume(state)

      true ->
        provision_fresh(state)
    end
  end

  defp provision_fresh(state) do
    # Enrich logging metadata with mission_id
    {is_phase_job, mission_id} =
      case GiTF.Ops.get(state.op_id) do
        {:ok, op} ->
          GiTF.Logger.set_ghost_context(state.ghost_id, state.op_id, op.mission_id)
          {Map.get(op, :phase_job, false), op.mission_id}

        _ ->
          {false, nil}
      end

    GiTF.Telemetry.start_ghost_span(state.ghost_id, state.op_id, mission_id)
    provision_start_ms = System.monotonic_time(:millisecond)

    with {:shell, {:ok, shell}} <- {:shell, create_shell(state)},
         {:update, :ok} <- {:update, update_ghost_working(state, shell)},
         {:transition, :ok} <- {:transition, maybe_transition_job(state)},
         {:agent, :ok} <- {:agent, maybe_ensure_agent(state, shell)} do
      # Apply role-based tool restrictions via settings.local.json
      role = role_for_job(state.op_id)
      GiTF.Runtime.Settings.generate_role_settings(role, shell.worktree_path)

      # Pre-dispatch: write op instructions so Claude Code has context at boot
      write_pre_dispatch(shell.worktree_path, state.op_id)

      # Build task-specific skill for non-phase ops (works for both API and CLI)
      if !is_phase_job do
        maybe_build_task_skill(build_prompt(state), shell.worktree_path, state.op_id)
      end

      case spawn_api_or_cli(state, shell) do
        {:ok, handle} ->
          Process.send_after(self(), :verify_beacon, timeout_cfg(:verify_beacon_initial_ms, 10_000))

          # Split metadata into bounded-cardinality `labels` (safe for Prometheus
          # label sets) and high-cardinality `attributes` (op_id, ghost_id,
          # mission_id — log/trace only, never label keys).
          GiTF.Telemetry.emit(
            [:gitf, :ghost, :spawned],
            %{duration_ms: System.monotonic_time(:millisecond) - provision_start_ms},
            %{
              labels: %{sector_id: state.sector_id, status: :spawned},
              attributes: %{
                ghost_id: state.ghost_id,
                op_id: state.op_id,
                mission_id: mission_id
              },
              # Legacy flat keys retained for existing listeners until migration
              ghost_id: state.ghost_id,
              op_id: state.op_id,
              mission_id: mission_id,
              sector_id: state.sector_id
            }
          )

          {:ok, attach_handle(state, shell, handle)}

        {:error, reason} ->
          Logger.warning(
            "Spawn failed for ghost #{state.ghost_id}, rolling back shell #{shell.id}"
          )

          rollback_shell(shell.id)
          {:error, reason}
      end
    else
      {step, {:error, reason}} ->
        # If shell was created but a later step failed, attempt cleanup.
        # We check whether shell_id is set by looking at state -- if create_shell
        # succeeded but a subsequent step failed, the shell variable is not in scope
        # here, so we look it up by ghost_id.
        rollback_shell_for_ghost(state.ghost_id)
        {:error, {step, reason}}
    end
  end

  defp ghost_restarting?(ghost_id) do
    case Archive.get(:ghosts, ghost_id) do
      %{status: status} -> status == GhostStatus.restarting()
      _ -> false
    end
  rescue
    e ->
      Logger.warning(
        "ghost_restarting? lookup failed for #{ghost_id}: #{Exception.message(e)}",
        ghost_id: ghost_id
      )

      false
  end

  defp provision_auto_resume(state) do
    # Enrich logging metadata with mission_id so resumed-ghost logs carry
    # the same structured context as fresh provisioning.
    case GiTF.Ops.get(state.op_id) do
      {:ok, op} -> GiTF.Logger.set_ghost_context(state.ghost_id, state.op_id, op.mission_id)
      _ -> :ok
    end

    # Look up shell via ghost record (O(1)) or fall back to linear scan
    shell_record =
      case Archive.get(:ghosts, state.ghost_id) do
        %{shell_id: sid} when is_binary(sid) -> Archive.get(:shells, sid)
        _ -> Archive.find_one(:shells, fn c -> c.ghost_id == state.ghost_id end)
      end

    case shell_record do
      %{worktree_path: path} = shell when is_binary(path) ->
        if File.dir?(path) do
          # Build resume context from transfer/backup
          resume_context = build_resume_context(state.ghost_id)
          original_prompt = build_prompt(state)

          prompt =
            if resume_context do
              # Truncate original prompt to avoid 2x token load on resume.
              # The transfer context already has the task state; the original
              # prompt's artifact dumps are redundant for continuation.
              truncated =
                if byte_size(original_prompt) > 4000 do
                  String.slice(original_prompt, 0, 4000) <>
                    "\n\n[... prompt truncated for context efficiency — refer to transfer context above for full state ...]"
                else
                  original_prompt
                end

              resume_context <> "\n\n---\n\nContinue the following task:\n\n" <> truncated
            else
              original_prompt
            end

          # Reset op back to running
          case GiTF.Ops.get(state.op_id) do
            {:ok, %{status: s}} when s in ["failed", "pending"] -> GiTF.Ops.start(state.op_id)
            _ -> :ok
          end

          state = %{state | opts: Keyword.put(state.opts, :prompt, prompt)}

          with :ok <- update_ghost_working(state, shell),
               {:ok, handle} <- spawn_api_or_cli(state, shell) do
            Process.send_after(self(), :verify_beacon, timeout_cfg(:verify_beacon_initial_ms, 10_000))
            {:ok, attach_handle(state, shell, handle)}
          else
            error ->
              Logger.warning(
                "Auto-resume failed for ghost #{state.ghost_id}: #{inspect(error)}, falling back to fresh"
              )

              provision_fresh(state)
          end
        else
          Logger.warning(
            "Shell path #{path} gone for ghost #{state.ghost_id}, falling back to fresh"
          )

          provision_fresh(state)
        end

      _ ->
        Logger.warning("No shell found for ghost #{state.ghost_id}, falling back to fresh")
        provision_fresh(state)
    end
  end

  defp build_resume_context(ghost_id) do
    case GiTF.Transfer.detect_handoff(ghost_id) do
      {:ok, link_msg} ->
        case GiTF.Transfer.resume(ghost_id, link_msg.id) do
          {:ok, briefing} -> briefing
          _ -> build_resume_from_backup(ghost_id)
        end

      _ ->
        build_resume_from_backup(ghost_id)
    end
  rescue
    _ -> nil
  end

  defp build_resume_from_backup(ghost_id) do
    case GiTF.Backup.load(ghost_id) do
      {:ok, backup} -> GiTF.Backup.build_resume_prompt(backup)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp spawn_api_or_cli(state, shell) do
    result =
      if state.execution_mode in [:api, :ollama, :bedrock] do
        spawn_process(state, shell)
      else
        spawn_process_with_timeout(state, shell)
      end

    case result do
      {:ok, %Task{} = task} -> {:ok, {:task, task}}
      {:ok, port} when is_port(port) -> {:ok, {:port, port}}
      error -> error
    end
  end

  defp attach_handle(state, shell, handle) do
    os_pid =
      case handle do
        {:port, port} -> GiTF.Runtime.OsProc.port_pid(port)
        _ -> nil
      end

    # Persist the OS pid on the ghost record so external supervisors (Janitor
    # hard-stall recovery, Ghosts.stop) can kill a wedged ghost's subprocess
    # even when the Worker GenServer itself is unresponsive.
    persist_os_pid(state.ghost_id, os_pid)

    %{
      state
      | shell_id: shell.id,
        status: :running,
        handle: handle,
        os_pid: os_pid,
        started_at: System.monotonic_time(:second)
    }
  end

  defp persist_os_pid(_ghost_id, nil), do: :ok

  defp persist_os_pid(ghost_id, os_pid) do
    Archive.update(:ghosts, ghost_id, fn ghost -> Map.put(ghost, :pid, os_pid) end)
    :ok
  rescue
    _ -> :ok
  end

  defp provision_revive(state) do
    # Enrich logging metadata with mission_id so revived-ghost logs carry
    # the same structured context as fresh provisioning.
    case GiTF.Ops.get(state.op_id) do
      {:ok, op} -> GiTF.Logger.set_ghost_context(state.ghost_id, state.op_id, op.mission_id)
      _ -> :ok
    end

    shell_id = Keyword.fetch!(state.opts, :shell_id)

    with {:ok, shell} <- GiTF.Shell.get(shell_id),
         :ok <- update_ghost_working(state, shell),
         {:ok, handle} <- spawn_api_or_cli(state, shell) do
      {:ok, attach_handle(state, shell, handle)}
    end
  end

  defp create_shell(state) do
    shell_opts = [gitf_root: state.gitf_root]

    shell_opts =
      case Keyword.get(state.opts, :base_branch) do
        nil -> shell_opts
        base when is_binary(base) -> Keyword.put(shell_opts, :base_branch, base)
      end

    GiTF.Shell.create(state.sector_id, state.ghost_id, shell_opts)
  end

  defp role_for_job(op_id) do
    case GiTF.Ops.get(op_id) do
      {:ok, %{recon: true}} -> :recon
      _ -> :builder
    end
  end

  defp update_ghost_working(state, shell) do
    case Archive.update(:ghosts, state.ghost_id, fn ghost ->
           Map.merge(ghost, %{
             status: GhostStatus.working(),
             shell_id: shell.id,
             shell_path: shell.worktree_path,
             pid: inspect(self())
           })
         end) do
      {:ok, _} -> :ok
      {:error, :not_found} -> {:error, :ghost_not_found}
      {:error, _} = err -> err
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

  defp spawn_process_with_timeout(state, shell) do
    caller = self()
    timeout = GiTF.Config.get(:spawn_timeout_ms) || 30_000

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
      timeout ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)
        Logger.error("Ghost #{state.ghost_id} spawn timed out after #{timeout}ms")
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

  # Builds provider-specific LLM options based on the op's context.
  # Currently derives `:google_thinking_budget` from the mission's triage
  # complexity: trivial/simple get budget=0 (disable extended thinking,
  # since they don't benefit from reasoning loops and pay wall-clock for
  # them). Moderate gets a low budget. Complex/unknown omit the option
  # and let the provider use its dynamic default.
  #
  # Takes effect only for gemini-family models; other providers ignore
  # the option harmlessly.
  defp provider_opts_for_op(op_id) do
    case GiTF.Ops.get(op_id) do
      {:ok, op} ->
        complexity = triage_complexity_for_mission(Map.get(op, :mission_id))
        model = Map.get(op, :assigned_model, "") || ""
        is_phase = Map.get(op, :phase_job, false)
        phase = Map.get(op, :phase)

        case thinking_budget_for(complexity, is_phase, phase, model) do
          nil -> []
          budget -> [google_thinking_budget: budget]
        end

      _ ->
        []
    end
  end

  defp triage_complexity_for_mission(nil), do: nil

  defp triage_complexity_for_mission(mission_id) do
    case GiTF.Missions.get_artifact(mission_id, "triage") do
      %{} = triage ->
        triage
        |> Map.get("complexity")
        |> GiTF.Triage.complexity_from_string()

      _ ->
        nil
    end
  end

  # Determines the `:google_thinking_budget` to pass to gemini for an op.
  # Returns nil when the option should be omitted (let provider use default).
  #
  # The trick: budget=0 disables thinking entirely on flash, which is great
  # for fast read-only phases (triage, research). But Google REJECTS
  # budget=0 on gemini-2.5-pro ("Budget 0 is invalid. This model only works
  # in thinking mode."), and small positive budgets (≤1024) on pro impl
  # prompts cause pro to burn budget on thinking and return empty text.
  #
  # So: budget=0 only applies when the model can accept it. For pro on
  # any op, omit the option — pro decides. We accept that pro is slower;
  # an empty response would be worse.
  defp thinking_budget_for(complexity, is_phase, phase, model) do
    case raw_thinking_budget(complexity, is_phase, phase) do
      0 -> if thinking_only_model?(model), do: nil, else: 0
      other -> other
    end
  end

  # phase_job: true with read-only phases (research, triage, etc.) doesn't
  # need thinking — these are fast scans, not reasoning-heavy.
  defp raw_thinking_budget(_complexity, true, phase)
       when phase in ["triage", "research", "requirements", "validation", "simplify", "scoring"],
       do: 0

  defp raw_thinking_budget(complexity, _is_phase, _phase) when complexity in [:trivial, :simple],
    do: 0

  defp raw_thinking_budget(:moderate, _is_phase, _phase), do: 2048
  defp raw_thinking_budget(_, _, _), do: nil

  # Models that Google rejects budget=0 on — extended-thinking-only variants.
  defp thinking_only_model?(model) when is_binary(model) do
    String.contains?(model, "gemini-2.5-pro")
  end

  defp thinking_only_model?(_), do: false

  defp spawn_api_task(prompt, working_dir, spawn_opts, state) do
    ghost_id = state.ghost_id

    # Determine tool_set based on phase op type
    tool_set =
      case GiTF.Ops.get(state.op_id) do
        {:ok, %{phase_job: true, phase: phase}}
        when phase in ["research", "requirements", "review", "validation"] ->
          :readonly

        _ ->
          :standard
      end

    worker_pid = self()

    provider_opts = provider_opts_for_op(state.op_id)

    agent_opts =
      spawn_opts
      |> Keyword.put(:tool_set, tool_set)
      |> Keyword.put(:include_dynamic, true)
      |> Keyword.put(:provider_opts, provider_opts)
      |> Keyword.put(:on_progress, fn event ->
        send(worker_pid, {:agent_progress, ghost_id, event})
      end)

    # Run AgentLoop under the shared Task.Supervisor with async_nolink so an
    # AgentLoop crash does NOT bring down this Worker. The existing
    # {:DOWN, ref, :process, _, reason} handle_info clause already treats
    # such a crash as a job failure (calls mark_failed).
    task =
      Task.Supervisor.async_nolink(GiTF.TaskSupervisor, fn ->
        try do
          GiTF.Runtime.AgentLoop.run(prompt, working_dir, agent_opts)
        rescue
          e ->
            Logger.error("AgentLoop crashed for ghost #{ghost_id}: #{Exception.message(e)}")
            {:error, {:agent_loop_crash, Exception.message(e)}}
        end
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
        mtime_seconds =
          :calendar.datetime_to_gregorian_seconds(mtime) -
            :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})

        now_seconds = System.os_time(:second)
        # Consider fresh if written within the last hour
        now_seconds - mtime_seconds < timeout_cfg(:task_skill_freshness_seconds, 3600)

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

    research_model = GiTF.Runtime.ModelResolver.resolve("fast")

    case GiTF.Runtime.Models.generate_text(research_prompt,
           model: research_model,
           max_tokens: 1024
         ) do
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
      Logger.warning(
        "Task skill research failed (non-fatal): #{Exception.message(e)}",
        op_id: op_id
      )

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
    GiTF.Telemetry.end_current_span()

    # IMPORTANT: Save all op metadata BEFORE marking ghost as stopped.
    # Once the ghost is terminal, Tachikoma's cleanup_orphans can delete the shell
    # and worktree at any time. We must capture branch info, files changed, and
    # output summary while the shell still exists.
    op =
      case GiTF.Ops.get(state.op_id) do
        {:ok, j} -> j
        _ -> nil
      end

    is_phase_job = op && Map.get(op, :phase_job, false)

    if is_phase_job do
      collect_phase_output(state, op)
    else
      auto_commit_worktree(state)
    end

    # Gather all metadata, then write atomically to prevent partial updates
    metadata = gather_completion_metadata(state, is_phase_job)

    if metadata != %{} do
      Archive.update(:ops, state.op_id, fn op -> Map.merge(op, metadata) end)
    end

    # NOW mark the ghost as stopped — after all shell-dependent work is done
    update_ghost_status(state.ghost_id, GhostStatus.stopped())

    # Fail-fast: implementation/fix ops that produced zero file changes did
    # not actually do the work, even if the model claimed success. Marking
    # such ops "done" causes the orchestrator to advance to validation, which
    # then fails — wasting time and retry budget. Detect at completion time
    # and delegate to mark_failed so the standard retry path takes over.
    empty_completion? =
      not is_phase_job and Map.get(metadata, :files_changed, 0) == 0

    if empty_completion? do
      Logger.warning(
        "Op #{state.op_id}: ghost #{state.ghost_id} reported success with 0 file changes — marking failed"
      )

      mark_failed(state, "Ghost reported success but produced 0 file changes")
    else
      case GiTF.Ops.get(state.op_id) do
        {:ok, %{status: "done"}} ->
          :ok

        _ ->
          GiTF.Ops.complete(state.op_id)
          GiTF.Ops.unblock_dependents(state.op_id)
      end

      finish_mark_success(state, op, is_phase_job)
    end
  end

  defp finish_mark_success(state, op, is_phase_job) do

    # See :spawned event above — same labels/attributes split for cardinality safety.
    GiTF.Telemetry.emit([:gitf, :ghost, :completed], %{}, %{
      labels: %{status: :completed, sector_id: state.sector_id},
      attributes: %{ghost_id: state.ghost_id, op_id: state.op_id},
      ghost_id: state.ghost_id,
      op_id: state.op_id
    })

    record_costs_from_events(state)

    is_scout = op && Map.get(op, :recon, false)
    is_simplify = op && Map.get(op, :phase) == "simplify"
    skip_verification = op && Map.get(op, :skip_verification, false)

    cond do
      is_scout ->
        # Recon ops: link_msg Major with scout_complete and the raw output
        output = IO.iodata_to_binary(state.output)
        parent_op_id = Map.get(op, :scout_for)

        body =
          Jason.encode!(%{
            scout_op_id: state.op_id,
            parent_op_id: parent_op_id,
            output: output
          })

        GiTF.Link.send(state.ghost_id, "major", "scout_complete", body)

      is_phase_job and not is_simplify ->
        # Phase ops: single durable delivery via Link (persisted, waggle-recoverable).
        # No redundant GenServer.cast — it caused lock contention and duplicate toasts.
        session_id = GiTF.Runtime.Models.extract_session_id(Enum.reverse(state.parsed_events))
        body = "op_id: #{state.op_id}\nJob #{state.op_id} completed successfully (phase: #{op.phase})"
        body = if session_id, do: body <> "\nSession ID: #{session_id}", else: body
        {:ok, _link_msg} = GiTF.Link.send(state.ghost_id, "major", "job_complete", body)

      skip_verification ->
        # Simple ops skip tachikoma verification, go straight to Major
        GiTF.Link.send(
          state.ghost_id,
          "major",
          "job_complete",
          "op_id: #{state.op_id}\nJob #{state.op_id} completed (skip_verification)"
        )

      true ->
        # Standard ops (and Simplify phase ops): broadcast to Tachikoma for independent verification.
        # The Tachikoma verifies, then forwards to SyncQueue on pass.
        Phoenix.PubSub.broadcast(
          GiTF.PubSub,
          "tachikoma:review",
          {:review_job, state.op_id, state.ghost_id, state.shell_id}
        )

        # Durable backup link — uses "job_awaiting_verification" (not "job_complete")
        # so it doesn't trigger a duplicate toast. Major's link_received recovery can
        # pick this up if the PubSub broadcast to Tachikoma is dropped.
        GiTF.Link.send(
          state.ghost_id,
          "major",
          "job_awaiting_verification",
          "op_id: #{state.op_id}\nJob #{state.op_id} completed (awaiting verification)"
        )
    end

    GiTF.Progress.clear(state.ghost_id)
  end

  defp collect_phase_output(state, op) do
    raw_output = IO.iodata_to_binary(state.output)
    events = Enum.reverse(state.parsed_events)

    # For parallel planning ghosts, store each under a strategy-specific key
    # (e.g. "planning_minimal") so they don't overwrite each other.
    # Single-strategy planning or other phases use the phase name directly.
    artifact_key = planning_artifact_key(op)

    case GiTF.Major.PhaseCollector.collect(op.phase, raw_output, events) do
      {:ok, artifact} ->
        GiTF.Missions.store_artifact(op.mission_id, artifact_key, artifact)

      {:error, reason} ->
        Logger.warning(
          "Phase output parse failed for #{op.phase}: #{inspect(reason)}, storing raw output as fallback"
        )

        # Extract a useful summary from the raw output so fix ops get context
        summary = extract_fallback_summary(raw_output)

        fallback_artifact = %{
          "raw_output" => String.slice(raw_output, 0, 50_000) |> :binary.copy(),
          "parse_failed" => true,
          "parse_error" => inspect(reason),
          "summary" => summary,
          "overall_verdict" => "fail"
        }

        GiTF.Missions.store_artifact(op.mission_id, artifact_key, fallback_artifact)
    end
  rescue
    e ->
      Logger.warning("Phase output collection error: #{inspect(e)}, storing minimal fallback")
      raw_output = IO.iodata_to_binary(state.output)

      fallback_artifact = %{
        "raw_output" => String.slice(raw_output, 0, 50_000) |> :binary.copy(),
        "parse_failed" => true,
        "parse_error" => inspect(e)
      }

      artifact_key = planning_artifact_key(op)
      GiTF.Missions.store_artifact(op.mission_id, artifact_key, fallback_artifact)
  end

  # For parallel phase ops (design, planning, simplify) with a [strategy] tag in
  # the title, use a strategy-specific artifact key so parallel ghosts don't collide.
  defp planning_artifact_key(op) do
    cond do
      # Tournament-mode phases (today: validation) carry an op.variant
      # tag — write per-variant artifacts so the tournament can compare.
      is_binary(op[:variant]) and op[:variant] != "" ->
        "#{op.phase}_#{op[:variant]}"

      op.phase in ["design", "planning", "simplify"] ->
        case Regex.run(~r/\[([^\]]+)\]/, op.title || "") do
          [_, strategy] -> "#{op.phase}_#{String.replace(strategy, ~r/\s+/, "-")}"
          _ -> op.phase
        end

      true ->
        op.phase
    end
  end

  # Extract a meaningful summary from raw ghost output when JSON parsing fails.
  # Takes the last non-empty lines that aren't code fences or formatting.
  defp extract_fallback_summary(raw_output) do
    raw_output
    |> String.split("\n")
    |> Enum.reject(fn line ->
      trimmed = String.trim(line)
      trimmed == "" or String.starts_with?(trimmed, "```") or trimmed == "---"
    end)
    |> Enum.take(-10)
    |> Enum.join("\n")
    |> String.slice(0, 1000)
    |> :binary.copy()
    |> case do
      "" -> "Ghost output contained no parseable JSON"
      summary -> summary
    end
  end

  defp auto_commit_worktree(state) do
    case Archive.get(:shells, state.shell_id) do
      %{worktree_path: path} when is_binary(path) ->
        # All git calls go through safe_git_cmd/3 which enforces a timeout via
        # Task.Supervisor.async_nolink so a hung or crashing git subprocess
        # cannot wedge or kill the Worker GenServer.
        case safe_git_cmd(["status", "--porcelain"], path, 30_000) do
          {output, 0} when output != "" ->
            op_title =
              case GiTF.Ops.get(state.op_id) do
                {:ok, op} -> op.title
                _ -> "op #{state.op_id}"
              end

            # Add all changes except .claude/ (generated settings that cause merge conflicts)
            safe_git_cmd(["add", "-A"], path, 30_000)
            safe_git_cmd(["reset", "HEAD", "--", ".claude/"], path, 30_000)

            # Only commit if there are staged changes left
            case safe_git_cmd(["diff", "--cached", "--name-only"], path, 30_000) do
              {staged, 0} ->
                if String.trim(staged) != "" do
                  safe_git_cmd(["commit", "-m", "gitf: #{op_title}"], path, 30_000)
                  Logger.debug("Auto-committed changes in worktree for ghost #{state.ghost_id}")
                end

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
      Logger.warning(
        "Auto-commit failed for ghost #{state.ghost_id} op #{state.op_id}: #{Exception.message(e)}",
        ghost_id: state.ghost_id,
        op_id: state.op_id
      )

      :ok
  end

  # Runs a git command under a Task.Supervisor.async_nolink so:
  #   - hangs are bounded by `timeout_ms` (default 30s)
  #   - a crash in the shell-out task cannot bring down the Worker
  defp safe_git_cmd(args, cwd, timeout_ms) do
    git = System.find_executable("git") || "/usr/bin/git"

    task =
      Task.Supervisor.async_nolink(GiTF.TaskSupervisor, fn ->
        System.cmd(git, args, cd: cwd, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, 5_000) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        Logger.warning("git #{Enum.join(args, " ")} crashed: #{inspect(reason)}")
        {"git crashed: #{inspect(reason)}", 1}

      nil ->
        Logger.warning("git #{Enum.join(args, " ")} timed out after #{timeout_ms}ms")
        {"git command timed out", 1}
    end
  end

  # Collects all op metadata in one pass — branch info, files changed, output summary.
  # Returns a map to merge atomically via Archive.update. Each section is wrapped
  # in its own try/rescue so one failure (e.g. a hung/broken git repo) doesn't
  # discard the other sections (e.g. output_summary).
  defp gather_completion_metadata(state, is_phase_job) do
    shell =
      try do
        Archive.get(:shells, state.shell_id)
      rescue
        e ->
          Logger.error(
            "Ghost #{state.ghost_id}: shell lookup failed: " <>
              Exception.format(:error, e, __STACKTRACE__)
          )

          nil
      end

    metadata = %{}

    # Output summary — always preserve this even if other sections fail.
    metadata =
      try do
        output = IO.iodata_to_binary(state.output)

        summary =
          output
          |> String.split("\n")
          |> Enum.reject(&(String.trim(&1) == ""))
          |> Enum.take(-20)
          |> Enum.join("\n")
          |> String.slice(0, 2000)
          |> :binary.copy()

        Map.put(metadata, :output_summary, summary)
      rescue
        e ->
          Logger.error(
            "Ghost #{state.ghost_id}: output summary failed: " <>
              Exception.format(:error, e, __STACKTRACE__)
          )

          metadata
      end

    # Branch info
    metadata =
      try do
        case shell do
          %{branch: branch} when is_binary(branch) ->
            Logger.debug("Ghost #{state.ghost_id}: saved branch #{branch} on op #{state.op_id}")
            Map.merge(metadata, %{branch: branch, shell_id: state.shell_id})

          nil ->
            Logger.warning("Ghost #{state.ghost_id}: shell #{inspect(state.shell_id)} not found for branch info")
            metadata

          _ ->
            metadata
        end
      rescue
        e ->
          Logger.error(
            "Ghost #{state.ghost_id}: branch metadata failed: " <>
              Exception.format(:error, e, __STACKTRACE__)
          )

          metadata
      end

    # Files changed (only for non-phase ops)
    metadata =
      if not is_phase_job do
        try do
          case shell do
            %{worktree_path: path, base_commit_sha: base} when is_binary(path) and is_binary(base) ->
              collect_file_changes(state, metadata, path, "#{base}..HEAD")

            %{worktree_path: path} when is_binary(path) ->
              collect_file_changes(state, metadata, path, "HEAD~1..HEAD")

            nil ->
              Logger.warning("Ghost #{state.ghost_id}: shell not found for record_files_changed")
              metadata

            _ ->
              metadata
          end
        rescue
          e ->
            Logger.error(
              "Ghost #{state.ghost_id}: files_changed metadata failed: " <>
                Exception.format(:error, e, __STACKTRACE__)
            )

            metadata
        end
      else
        metadata
      end

    metadata
  end

  defp collect_file_changes(state, metadata, worktree_path, range) do
    case GiTF.Git.safe_cmd(["diff", "--name-status", range],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        details = parse_name_status(output)
        files = Enum.map(details, & &1.path)
        Logger.info("Op #{state.op_id}: diff #{range} found #{length(files)} files changed")

        Map.merge(metadata, %{
          files_changed: length(files),
          changed_files: files,
          changed_files_detail: details
        })

      {output, code} ->
        Logger.warning("Op #{state.op_id}: git diff failed (exit #{code}): #{String.slice(output, 0, 200)}")
        metadata
    end
  end

  defp parse_name_status(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case String.split(line, "\t", parts: 2) do
        [status, path] -> %{status: String.first(status), path: path}
        [path] -> %{status: "M", path: path}
      end
    end)
  end

  defp format_api_error(final_reason, nil), do: "API error: #{inspect(final_reason)}"

  defp format_api_error(final_reason, first_reason) do
    "API error: #{inspect(final_reason)} (initial: #{inspect(first_reason)})"
  end

  defp mark_failed(state, reason) do
    # Record costs before marking ghost as terminal — shell may be cleaned up after
    record_costs_from_events(state)

    update_ghost_status(state.ghost_id, GhostStatus.crashed())
    GiTF.Ops.fail(state.op_id)

    mission_id =
      case GiTF.Ops.get(state.op_id) do
        {:ok, %{mission_id: mid}} -> mid
        _ -> nil
      end

    GiTF.Telemetry.emit([:gitf, :ghost, :failed], %{}, %{
      labels: %{status: :failed, sector_id: state.sector_id},
      attributes: %{
        ghost_id: state.ghost_id,
        op_id: state.op_id,
        mission_id: mission_id
      },
      ghost_id: state.ghost_id,
      op_id: state.op_id,
      mission_id: mission_id,
      error: reason
    })

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

  # Crash/shutdown variant: best-effort record of any token usage
  # captured before the crash. Wrapped in try/rescue because the
  # terminate handler must never crash itself — and shielded against
  # missing state fields (some restart paths terminate before
  # parsed_events is populated).
  defp record_partial_costs(state) do
    if Map.get(state, :parsed_events, []) != [] do
      record_costs_from_events(state)
    end
  rescue
    e ->
      Logger.warning(
        "Ghost #{state.ghost_id} record_partial_costs failed: #{Exception.message(e)}",
        ghost_id: state.ghost_id,
        op_id: state.op_id
      )

      :ok
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

            installed_skills =
              GiTF.AgentProfile.install_agents_and_skills(
                sector.path,
                shell.worktree_path,
                %{title: op.title, description: op.description},
                shell.sector_id
              )

            track_applied_skills(state.op_id, installed_skills)
            :ok

          _sector ->
            :ok
        end

      {:error, _} ->
        :ok
    end
  end

  # Stashes the list of applied skill IDs on the op record so Milestone 2
  # refinement can attribute validation outcomes to specific skills.
  defp track_applied_skills(_op_id, []), do: :ok

  defp track_applied_skills(op_id, skill_ids) do
    GiTF.Archive.update(:ops, op_id, fn op ->
      existing = Map.get(op, :applied_skill_ids, [])
      Map.put(op, :applied_skill_ids, Enum.uniq(existing ++ skill_ids))
    end)

    :ok
  rescue
    e ->
      Logger.debug("track_applied_skills failed for op #{op_id}: #{Exception.message(e)}")
      :ok
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
            Logger.warning(
              "Ghost #{ghost_id} needs transfer - context at critical level, triggering"
            )

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

  # Transient error shapes where an immediate retry of the same model is
  # more likely to succeed than a fallback switch. Narrowly scoped — real
  # auth/billing/model-not-found errors fall through to fallback.
  defp retry_same_model?(_reason, %{same_model_retries: n}) when n >= @max_same_model_retries,
    do: false

  defp retry_same_model?({:api_error, :empty_response}, _state), do: true
  defp retry_same_model?({:api_error, :thinking_only_response}, _state), do: true
  defp retry_same_model?({:api_error, {:agent_loop_crash, _}}, _state), do: true
  defp retry_same_model?({:api_error, %{reason: "timeout"}}, _state), do: true
  defp retry_same_model?({:api_error, %{reason: :timeout}}, _state), do: true
  defp retry_same_model?({:api_error, %{cause: %{reason: :timeout}}}, _state), do: true

  # Some providers (BedrockDirect) surface errors as strings. A timeout must
  # take the cheap same-model retry, not the fallback path — falling back
  # respawns a different model from scratch and re-pays the whole phase's
  # accumulated input tokens.
  defp retry_same_model?({:api_error, reason}, _state) when is_binary(reason),
    do: String.contains?(String.downcase(reason), "timeout")

  defp retry_same_model?(_reason, _state), do: false

  defp fallback_or_fail(reason, state) do
    case maybe_fallback_model(state) do
      {:ok, new_task, fallback_model} ->
        Logger.info("Ghost #{state.ghost_id} falling back to model #{fallback_model}")

        {:noreply,
         %{
           state
           | handle: {:task, new_task},
             fallback_attempted: true,
             first_error: state.first_error || reason
         }}

      :no_fallback ->
        mark_failed(state, format_api_error(reason, state.first_error))
        {:stop, :normal, %{state | status: :failed, handle: nil}}
    end
  end

  # Backoff before a same-model retry so an empty-response / timeout loop can't
  # thrash the API. Bounded (retries cap at 2) and short; the factory daily
  # budget cap is the hard cost backstop. Applied via send_after (see the retry
  # scheduler), NOT Process.sleep, so it never blocks the worker mailbox.
  defp same_model_backoff_ms(retries) do
    min(500 * (retries + 1) * (retries + 1), 4_000)
  end

  defp respawn_current_model(state) do
    with %{worktree_path: path} <- Archive.get(:shells, state.shell_id) do
      prompt = build_prompt(state)
      spawn_api_task(prompt, path, [], state)
    else
      _ -> :error
    end
  rescue
    e ->
      Logger.debug("respawn_current_model failed: #{inspect(e)}")
      :error
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

      if is_binary(fallback) and fallback != "" do
        # Update ghost record with fallback model atomically
        case Archive.update(:ghosts, state.ghost_id, fn ghost ->
               %{ghost | assigned_model: fallback}
             end) do
          {:ok, _} -> :ok
          _ -> :no_fallback
        end

        # Re-spawn the API task with fallback model
        case Archive.get(:shells, state.shell_id) do
          %{worktree_path: path} ->
            prompt = build_prompt(state)

            task =
              Task.Supervisor.async_nolink(GiTF.TaskSupervisor, fn ->
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
    shutdown_handle(state, 5_000)
    update_ghost_status(state.ghost_id, GhostStatus.stopped())
    %{state | status: :done, handle: nil}
  rescue
    ArgumentError -> %{state | status: :done, handle: nil}
  end

  defp update_ghost_status(ghost_id, status) do
    case Archive.update(:ghosts, ghost_id, fn ghost -> %{ghost | status: status} end) do
      {:ok, _} ->
        :ok

      other ->
        # A failed terminal-status write leaves a dead ghost marked "working",
        # which corrupts pool-saturation and stall detection. Surface it.
        Logger.warning(
          "Ghost #{ghost_id}: failed to persist status #{inspect(status)}: #{inspect(other)}"
        )

        :ok
    end
  end

  defp port_alive?(port) do
    Port.info(port) != nil
  rescue
    ArgumentError -> false
  end

  defp schedule_checkpoint do
    Process.send_after(self(), :backup, timeout_cfg(:checkpoint_interval_ms, 30_000))
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

  defp rollback_shell(shell_id) do
    GiTF.Shell.remove(shell_id, force: true)
  rescue
    e ->
      Logger.debug("Cell rollback failed for #{shell_id}: #{inspect(e)}")
      :ok
  end

  defp rollback_shell_for_ghost(ghost_id) do
    case Archive.find_one(:shells, fn c -> c.ghost_id == ghost_id and c.status == "active" end) do
      nil -> :ok
      shell -> rollback_shell(shell.id)
    end
  rescue
    _ -> :ok
  end

  # Timeouts are tuned via `config :gitf, :timeouts` at runtime.
  defp timeout_cfg(key, default), do: Application.get_env(:gitf, :timeouts, [])[key] || default
end
