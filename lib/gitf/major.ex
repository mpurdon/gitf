defmodule GiTF.Major do
  @moduledoc """
  GenServer for the Major orchestrator process.

  The Major coordinates work across ghosts by subscribing to link_msg messages
  and reacting to status updates. This is a thin GenServer -- the business
  logic for link_msg processing lives in `GiTF.Link` and `GiTF.Brief`,
  while the Major merely maintains session state and dispatches reactions.

  ## State

      %{
        status: :idle | :active,
        active_ghosts: %{ghost_id => bee_info},
        gitf_root: String.t()
      }

  ## Lifecycle

  The Major is NOT auto-started by the Application supervisor. It is
  started on-demand when the user runs `gitf major`, and uses a
  `:transient` restart strategy so it stays down if stopped gracefully.
  """

  use GenServer
  require Logger

  require GiTF.Ghost.Status, as: GhostStatus

  @name GiTF.Major
  @waggle_recovery_interval :timer.seconds(30)
  @waggle_stale_seconds 30

  # -- Client API ------------------------------------------------------------

  @doc """
  Starts the Major GenServer.

  ## Options

    * `:gitf_root` - the root directory of the gitf workspace (required)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    gitf_root = Keyword.fetch!(opts, :gitf_root)
    GenServer.start_link(__MODULE__, %{gitf_root: gitf_root}, name: @name)
  end

  @doc "Activates the Major session. Sets status to `:active`."
  @spec start_session() :: :ok
  def start_session do
    GenServer.call(@name, :start_session)
  end

  @doc "Deactivates the Major session. Sets status to `:idle`."
  @spec stop_session() :: :ok
  def stop_session do
    GenServer.call(@name, :stop_session)
  end

  @doc """
  Launches an interactive Claude session for the Major.

  Sets up the queen workspace with settings, then spawns Claude
  interactively. The GenServer monitors the port and handles its
  messages alongside link_msg processing.
  """
  @spec launch() :: :ok | {:error, term()}
  def launch do
    GenServer.call(@name, :launch)
  end

  @doc "Returns the current Major state for inspection."
  @spec status() :: map()
  def status do
    GenServer.call(@name, :status)
  end

  @doc "Blocks until the Major's Claude session exits."
  @spec await_session_end() :: :ok
  def await_session_end do
    GenServer.call(@name, :await_session_end, :infinity)
  end

  # -- GenServer callbacks ---------------------------------------------------

  @impl true
  def init(%{gitf_root: gitf_root}) do
    GiTF.Logger.set_major_context()

    # Subscribe to link_msg messages addressed to the queen
    GiTF.Link.subscribe("link:major")

    max_ghosts = read_max_ghosts(gitf_root)

    state = %{
      status: :idle,
      active_ghosts: %{},
      gitf_root: gitf_root,
      port: nil,
      max_ghosts: max_ghosts,
      effective_max_ghosts: max_ghosts,
      max_retries: 3,
      last_checkpoint: %{},
      stall_timeout: :timer.minutes(10),
      pending_verifications: %{},
      clarification_timers: %{},
      retry_pending: MapSet.new(),
      recovery_pending: MapSet.new()
    }

    # Tachikoma is now supervised by Application — just verify it's running
    case GiTF.Tachikoma.lookup() do
      {:ok, _pid} -> Logger.debug("Tachikoma is running")
      :error -> Logger.warning("Tachikoma is not running")
    end

    # Subscribe to config reload events so max_ghosts/budget/model changes
    # take effect without restarting Major.
    GiTF.Config.Provider.subscribe()

    Logger.info("Major initialized at #{gitf_root}")

    # Recover stuck ops whose worker processes died
    recover_stuck_jobs()

    # Recover any missed links from before we started
    send(self(), :recover_missed_waggles)
    schedule_waggle_recovery()

    # Periodically check for pending ops that need ghosts
    schedule_job_spawner()

    # Periodically check for stalled ghosts
    schedule_stall_check()

    # Periodically recover stuck ops (workers died without link_msg)
    schedule_stuck_recovery()

    # Periodically check post-review windows
    schedule_debrief_check()

    # Periodically advance stuck mission phases
    schedule_phase_advancement()

    # Periodically run janitor maintenance when idle
    schedule_janitor()

    # Periodically re-evaluate ghost capacity against budget pressure
    schedule_autoscale()

    # Resume active missions via handle_continue — runs immediately after
    # init completes but before any other message is processed. Registry
    # and Archive are already started (earlier in the supervision tree).
    {:ok, state, {:continue, :resume_active_quests}}
  end

  @impl true
  def handle_call(:start_session, _from, state) do
    Logger.info("Major session started")
    {:reply, :ok, %{state | status: :active}}
  end

  def handle_call(:stop_session, _from, state) do
    Logger.info("Major session stopped")
    {:reply, :ok, %{state | status: :idle}}
  end

  def handle_call(:launch, _from, state) do
    case launch_claude_session(state) do
      {:ok, port} ->
        {:reply, :ok, %{state | port: port, status: :active}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply,
     Map.take(state, [
       :status,
       :active_ghosts,
       :gitf_root,
       :max_ghosts,
       :effective_max_ghosts
     ]), state}
  end

  def handle_call(:await_session_end, from, state) do
    {:noreply, Map.put(state, :awaiter, from)}
  end

  @impl true
  def handle_cast({:phase_complete, ghost_id, op_id, mission_id}, state) do
    # Direct notification from ghost worker — bypasses PubSub for reliability
    Logger.info("Phase complete (direct): ghost=#{ghost_id} op=#{op_id} mission=#{mission_id}")
    notify_run_job_completed(op_id)
    state = advance_quest(ghost_id, state)
    {:noreply, state}
  end

  def handle_cast({:apply_autoscale, target, meta}, state) do
    {:noreply, apply_autoscale(state, target, meta)}
  end

  def handle_cast(_msg, state), do: {:noreply, state}

  @impl true
  def handle_continue(:resume_active_quests, state) do
    resume_active_quests(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:waggle_received, link_msg}, state) do
    state = handle_waggle(link_msg, state)
    # Mark as read to prevent re-processing by the 30s waggle recovery cycle
    if id = Map.get(link_msg, :id), do: GiTF.Link.mark_read(id)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, _status}}, %{port: port} = state) when is_port(port) do
    Logger.info("Major's Claude session ended")

    if state[:awaiter] do
      GenServer.reply(state.awaiter, :ok)
    end

    {:noreply, %{state | port: nil, status: :idle, awaiter: nil}}
  end

  # API mode: Task completion
  def handle_info({ref, {:ok, _result}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    Logger.info("Major's API session completed")

    if state[:awaiter] do
      GenServer.reply(state.awaiter, :ok)
    end

    {:noreply, %{state | port: nil, status: :idle, awaiter: nil}}
  end

  def handle_info({ref, {:error, reason}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    Logger.warning("Major's API session failed: #{inspect(reason)}")

    if state[:awaiter] do
      GenServer.reply(state.awaiter, :ok)
    end

    {:noreply, %{state | port: nil, status: :idle, awaiter: nil}}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) when is_pid(pid) do
    # Check if this is a ghost worker dying — look up via Registry
    ghost_id =
      GiTF.Registry
      |> Registry.select([{{{:ghost, :"$1"}, pid, :_}, [], [:"$1"]}])
      |> List.first()

    if ghost_id do
      state =
        if reason != :normal do
          Logger.warning("Ghost worker #{ghost_id} died unexpectedly: #{inspect(reason)}")
          handle_ghost_death(ghost_id, state)
        else
          state
        end

      {:noreply, update_in(state.active_ghosts, &Map.delete(&1, ghost_id))}
    else
      # Not a ghost worker — likely the API session process
      Logger.warning("Major's API session process died: #{inspect(reason)}")

      if state[:awaiter] do
        GenServer.reply(state.awaiter, :ok)
      end

      {:noreply, state |> Map.put(:port, nil) |> Map.put(:status, :idle) |> Map.put(:awaiter, nil)}
    end
  end

  def handle_info({ref, {:verification_passed, ghost_id, op_id}}, state) do
    # Flush task monitor
    Process.demonitor(ref, [:flush])
    state = %{state | pending_verifications: Map.delete(state.pending_verifications, ref)}
    Logger.info("Audit passed for op #{op_id} (ghost #{ghost_id})")
    notify_run_job_completed(op_id)
    GiTF.Ops.unblock_dependents(op_id)
    GiTF.Trust.update_after_job(op_id)
    state = advance_quest(ghost_id, state)
    {:noreply, state}
  end

  def handle_info({ref, {:verification_failed, ghost_id, op_id, result}}, state) do
    Process.demonitor(ref, [:flush])
    state = %{state | pending_verifications: Map.delete(state.pending_verifications, ref)}
    Logger.warning("Audit failed for op #{op_id}: #{inspect(result[:output])}")
    notify_run_job_failed(op_id)
    GiTF.Trust.update_after_job(op_id)

    # Treat as op failure -> trigger retry logic
    link_msg = %{
      from: ghost_id,
      subject: "verification_failed",
      body: "Audit failed: #{result[:output]}"
    }

    state = maybe_retry_job(link_msg, state)
    {:noreply, state}
  end

  def handle_info({ref, {:verification_error, ghost_id, op_id, reason}}, state) do
    Process.demonitor(ref, [:flush])
    state = %{state | pending_verifications: Map.delete(state.pending_verifications, ref)}
    Logger.error("Audit system error for op #{op_id}: #{inspect(reason)}")

    # Fail safe: retry
    link_msg = %{
      from: ghost_id,
      subject: "verification_error",
      body: "System error during verification: #{inspect(reason)}"
    }

    state = maybe_retry_job(link_msg, state)
    {:noreply, state}
  end

  def handle_info(:recover_missed_waggles, state) do
    state = recover_missed_waggles(state)
    {:noreply, state}
  end

  def handle_info(:schedule_waggle_recovery, state) do
    state = recover_missed_waggles(state)
    schedule_waggle_recovery()
    {:noreply, state}
  end

  def handle_info(:spawn_ready_jobs, state) do
    state = spawn_all_ready_jobs(state)
    schedule_job_spawner()
    {:noreply, state}
  end

  def handle_info(:check_stalls, state) do
    detect_stalled_bees(state)
    schedule_stall_check()
    {:noreply, state}
  end

  def handle_info(:recover_stuck, state) do
    recover_stuck_jobs()
    timeout_stale_jobs()
    schedule_stuck_recovery()
    {:noreply, state}
  end

  def handle_info(:check_debriefs, state) do
    check_debriefs()
    schedule_debrief_check()
    {:noreply, state}
  end

  def handle_info(:advance_stuck_phases, state) do
    advance_stuck_mission_phases()
    schedule_phase_advancement()
    {:noreply, state}
  end

  def handle_info(:janitor_run, state) do
    GiTF.Major.Janitor.run_if_idle()
    schedule_janitor()
    {:noreply, state}
  end

  def handle_info(:autoscale_check, state) do
    dispatch_autoscale(state.max_ghosts)
    schedule_autoscale()
    {:noreply, state}
  end

  def handle_info({:config_reloaded, changed_keys}, state) do
    state =
      if :major in changed_keys or :queen in changed_keys do
        new_max = read_max_ghosts(state.gitf_root)

        if new_max != state.max_ghosts do
          Logger.info("Config reload: max_ghosts #{state.max_ghosts} → #{new_max}")
          # Trigger an immediate autoscale cycle with the new ceiling
          dispatch_autoscale(new_max)
          %{state | max_ghosts: new_max}
        else
          state
        end
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:delayed_retry, op_id, feedback}, state) do
    Logger.info("Executing delayed retry for op #{op_id}")
    state = %{state | retry_pending: MapSet.delete(state.retry_pending, op_id)}

    if retry_exists?(op_id) do
      Logger.debug("Delayed retry skipped for op #{op_id}: retry already exists in store")
      {:noreply, state}
    else
      case GiTF.Ops.get(op_id) do
        {:ok, %{status: "failed"}} ->
          case try_intelligent_retry(op_id, feedback, state) do
            {:ok, _} -> {:noreply, state}
            {:error, _} -> {:noreply, simple_retry(op_id, feedback, state)}
          end

        {:ok, %{status: status}} ->
          Logger.debug("Delayed retry skipped for op #{op_id}: status is #{status}")
          {:noreply, state}

        {:error, _} ->
          Logger.debug("Delayed retry skipped for op #{op_id}: op not found")
          {:noreply, state}
      end
    end
  end

  def handle_info({:clarification_timeout, ghost_id, body}, state) do
    state = %{state | clarification_timers: Map.delete(state.clarification_timers, ghost_id)}

    # Auto-resolve clarification after timeout — retry the ghost's op with simplified instructions
    case GiTF.Ghosts.get(ghost_id) do
      {:ok, ghost} when not is_nil(ghost.op_id) ->
        case GiTF.Ops.get(ghost.op_id) do
          {:ok, op} when op.status in ["running", "assigned"] ->
            Logger.warning(
              "Clarification timeout for ghost #{ghost_id}, auto-resolving op #{op.id}"
            )

            GiTF.Observability.Alerts.dispatch_webhook(
              :clarification_auto_resolved,
              "Ghost #{ghost_id} clarification timed out after 15m — retrying op #{op.id} with simplified scope"
            )

            # Fail the current op so retry logic picks it up with feedback
            GiTF.Ops.fail(op.id)

            feedback =
              "Previous attempt requested clarification: #{String.slice(body, 0, 500)}. " <>
                "Proceed with your best interpretation. If instructions are ambiguous, choose the simplest approach."

            send(self(), {:delayed_retry, op.id, feedback})

          _ ->
            :ok
        end

      _ ->
        :ok
    end

    {:noreply, state}
  rescue
    e ->
      Logger.warning(
        "Clarification timeout handler failed for ghost #{ghost_id}: #{Exception.message(e)}"
      )

      {:noreply, state}
  end

  def handle_info({:check_ghost_recovery, ghost_id, op_id}, state) do
    state = %{state | recovery_pending: MapSet.delete(state.recovery_pending, ghost_id)}

    case GiTF.Ghost.Worker.lookup(ghost_id) do
      {:ok, _pid} ->
        Logger.info("Ghost #{ghost_id} recovered by supervisor, re-monitoring")
        monitor_ghost_worker(ghost_id)
        {:noreply, state}

      :error ->
        case GiTF.Ghosts.get(ghost_id) do
          {:ok, %{status: s} = ghost}
          when s in [GhostStatus.restarting(), GhostStatus.working(), GhostStatus.starting()] ->
            Logger.warning("Ghost #{ghost_id} did not recover, failing op #{op_id}")
            GiTF.Archive.put(:ghosts, %{ghost | status: GhostStatus.crashed()})
            GiTF.Ops.fail(op_id)

            GiTF.Link.send(
              ghost_id,
              "major",
              "job_failed",
              "Ghost #{ghost_id} worker died and could not be auto-resumed"
            )

          _ ->
            :ok
        end

        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("Major received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # -- Private: stuck op recovery --------------------------------------------

  defp recover_stuck_jobs do
    stuck_jobs =
      GiTF.Archive.filter(:ops, fn j -> j.status == "running" end)

    Enum.each(stuck_jobs, fn op ->
      worker_alive? =
        case op.ghost_id do
          nil ->
            false

          ghost_id ->
            case GiTF.Ghost.Worker.lookup(ghost_id) do
              {:ok, pid} -> Process.alive?(pid)
              :error -> false
            end
        end

      if !worker_alive? do
        Logger.warning("Recovering stuck op #{op.id} (worker dead)")
        GiTF.Ops.fail(op.id)

        # Trigger retry via delayed_retry (same path as waggle-based failures)
        if !retry_exists?(op.id) do
          send(self(), {:delayed_retry, op.id, "Worker process died unexpectedly"})
        end
      end
    end)
  rescue
    e ->
      Logger.warning("Stuck op recovery failed: #{Exception.message(e)}")
  end

  # -- Private: op state timeout detection ------------------------------------

  @pending_timeout_seconds 600
  @assigned_timeout_seconds 600

  defp timeout_stale_jobs do
    now = DateTime.utc_now()

    # Timeout ops stuck in "pending" for too long (>10 min)
    GiTF.Archive.filter(:ops, fn j -> j.status == "pending" end)
    |> Enum.each(fn op ->
      age = DateTime.diff(now, op.updated_at || op.inserted_at, :second)

      if age > @pending_timeout_seconds do
        # Only fail if the op is supposed to be active (has a mission that's running)
        quest_active? =
          case GiTF.Archive.get(:missions, op.mission_id) do
            %{status: s} when s in ["active", "implementation"] -> true
            _ -> false
          end

        if quest_active? and GiTF.Ops.ready?(op.id) do
          Logger.warning("Job #{op.id} stuck pending for #{age}s, resetting")
          GiTF.Ops.fail(op.id)
          GiTF.Ops.reset(op.id, "Timed out in pending state after #{age}s")
        end
      end
    end)

    # Timeout ops stuck in "assigned" (ghost never started working)
    GiTF.Archive.filter(:ops, fn j -> j.status == "assigned" end)
    |> Enum.each(fn op ->
      age = DateTime.diff(now, op.updated_at || op.inserted_at, :second)

      if age > @assigned_timeout_seconds do
        Logger.warning("Job #{op.id} stuck assigned for #{age}s, failing for retry")
        GiTF.Ops.fail(op.id)
      end
    end)
  rescue
    e ->
      Logger.warning("Job timeout check failed: #{Exception.message(e)}")
  end

  # -- Private: link_msg handling ----------------------------------------------
  # Business logic is deliberately minimal here. The Major GenServer
  # dispatches to pattern-matched handlers. Heavier orchestration logic
  # will move to dedicated context modules as the system grows.

  defp handle_waggle(%{subject: "job_complete"} = link_msg, state) do
    Logger.info("Ghost #{link_msg.from} reports op complete. Initiating verification...")

    # We remove from active_ghosts immediately so Major doesn't think it's still "working"
    # but we don't advance mission yet.
    state = update_in(state.active_ghosts, &Map.delete(&1, link_msg.from))

    op_id = find_job_for_bee(link_msg.from)

    if op_id do
      # Phase ops (research, design, etc.) don't need verification — skip straight to advance
      case GiTF.Ops.get(op_id) do
        {:ok, %{phase_job: true} = op} ->
          Logger.info("Phase op #{op_id} completed, skipping verification")
          GiTF.Archive.put(:ops, Map.put(op, :verification_status, "skipped"))
          notify_run_job_completed(op_id)
          state = advance_quest(link_msg.from, state)
          state

        {:ok, %{verification_status: vs}} when vs in ["passed", "failed"] ->
          # Already verified (e.g., by worker inline) — skip Major-side verification
          Logger.info("Job #{op_id} already verified (#{vs}), skipping duplicate verification")

          if vs == "passed" do
            notify_run_job_completed(op_id)
            GiTF.Trust.update_after_job(op_id)
            advance_quest(link_msg.from, state)
          else
            notify_run_job_failed(op_id)

            waggle_msg = %{
              from: link_msg.from,
              subject: "verification_failed",
              body: "Already failed verification"
            }

            maybe_retry_job(waggle_msg, state)
          end

        _ ->
          # Implementation ops go through verification
          task =
            Task.async(fn ->
              case GiTF.Audit.verify_job(op_id) do
                {:ok, :pass, _result} -> {:verification_passed, link_msg.from, op_id}
                {:ok, :fail, result} -> {:verification_failed, link_msg.from, op_id, result}
                {:error, reason} -> {:verification_error, link_msg.from, op_id, reason}
              end
            end)

          pending = Map.put(state.pending_verifications, task.ref, {link_msg.from, op_id})
          %{state | pending_verifications: pending}
      end
    else
      Logger.warning("Could not find op for ghost #{link_msg.from}, skipping verification")
      # Fallback: try to advance anyway if we can't verify (orphan ghost?)
      state = advance_quest(link_msg.from, state)
      state
    end
  end

  defp handle_waggle(%{subject: "job_failed"} = link_msg, state) do
    Logger.warning("Ghost #{link_msg.from} reports op failed: #{link_msg.body}")
    state = update_in(state.active_ghosts, &Map.delete(&1, link_msg.from))

    op_id = find_job_for_bee(link_msg.from)
    if op_id, do: notify_run_job_failed(op_id)

    maybe_retry_job(link_msg, state)
  end

  defp handle_waggle(%{subject: "validation_failed"} = link_msg, state) do
    Logger.warning("Ghost #{link_msg.from} reports validation failed: #{link_msg.body}")
    state = update_in(state.active_ghosts, &Map.delete(&1, link_msg.from))
    maybe_retry_job(link_msg, state)
  end

  defp handle_waggle(%{subject: "merge_conflict_warning"} = link_msg, state) do
    Logger.warning("Sync conflict detected from ghost #{link_msg.from}: #{link_msg.body}")

    # Extract shell_id from the ghost record
    shell_id =
      case GiTF.Ghosts.get(link_msg.from) do
        {:ok, ghost} ->
          case GiTF.Archive.find_one(:shells, fn c -> c.ghost_id == ghost.id end) do
            nil -> nil
            shell -> shell.id
          end

        _ ->
          nil
      end

    if shell_id do
      # Attempt rebase-based resolution
      case GiTF.Conflict.resolve(shell_id, :rebase) do
        {:ok, :resolved} ->
          Logger.info("Conflict resolved via rebase for shell #{shell_id}")

          # Re-run validation after rebase before merging
          op_id = find_job_for_bee(link_msg.from)

          validation_ok? =
            if op_id do
              case GiTF.Validator.validate(link_msg.from, %{id: op_id}, shell_id) do
                {:ok, _} -> true
                _ -> false
              end
            else
              true
            end

          if validation_ok? do
            # Re-attempt sync after successful rebase + validation
            case GiTF.Sync.sync_back(shell_id) do
              {:ok, strategy} ->
                Logger.info("Post-rebase sync succeeded (#{strategy}) for shell #{shell_id}")
                state

              {:error, reason} ->
                Logger.warning(
                  "Post-rebase sync failed for shell #{shell_id}: #{inspect(reason)}"
                )

                reimagine_conflicted_job(shell_id, link_msg, state)
            end
          else
            Logger.warning("Post-rebase validation failed for shell #{shell_id}")
            reimagine_conflicted_job(shell_id, link_msg, state)
          end

        {:error, reason} ->
          Logger.warning("Conflict resolution failed for shell #{shell_id}: #{inspect(reason)}")
          reimagine_conflicted_job(shell_id, link_msg, state)
      end
    else
      # No shell found — reimagine directly by finding the op
      Logger.warning("No shell for ghost #{link_msg.from}, reimagining op directly")
      reimagine_conflicted_job(nil, link_msg, state)
    end
  end

  defp handle_waggle(%{subject: "merge_failed"} = link_msg, state) do
    Logger.warning("Sync failed from #{link_msg.from}: #{link_msg.body}")
    state
  end

  defp handle_waggle(%{subject: "job_merged"} = link_msg, state) do
    Logger.info("SyncQueue reports: #{link_msg.body}")

    # Extract op_id from body (format: "Job <op_id> merged successfully (tier N)")
    op_id = extract_op_id_from_body(link_msg.body)

    if op_id do
      notify_run_job_completed(op_id)

      ghost_id =
        case GiTF.Ops.get(op_id) do
          {:ok, op} -> op.ghost_id
          _ -> nil
        end

      if ghost_id do
        advance_quest(ghost_id, state)
      else
        state
      end
    else
      state
    end
  end

  defp handle_waggle(%{subject: "scout_complete"} = link_msg, state) do
    # A recon ghost finished. Parse its findings and inject them into the parent op.
    case Jason.decode(link_msg.body) do
      {:ok, %{"scout_op_id" => scout_op_id, "parent_op_id" => parent_op_id, "output" => output}} ->
        findings = GiTF.Recon.parse_findings(output)

        case GiTF.Recon.inject_findings(parent_op_id, findings) do
          {:ok, _updated} ->
            Logger.info("Recon findings injected into op #{parent_op_id}")

          {:error, reason} ->
            Logger.warning(
              "Failed to inject recon findings into #{parent_op_id}: #{inspect(reason)}"
            )
        end

        # Unblock dependents (the parent op depends on the recon op)
        GiTF.Ops.unblock_dependents(scout_op_id)

      _ ->
        Logger.warning("Invalid scout_complete link_msg body: #{link_msg.body}")
    end

    state
  end

  defp handle_waggle(%{subject: "job_retry_created"} = link_msg, state) do
    Logger.info("Tachikoma created retry op: #{link_msg.body}")
    # The retry op will be picked up by the periodic op spawner
    state
  end

  defp handle_waggle(%{subject: "job_exhausted_retries"} = link_msg, state) do
    Logger.warning("Job exhausted retries: #{link_msg.body}")
    state
  end

  defp handle_waggle(%{subject: "reimagine_job_created"} = link_msg, state) do
    Logger.info("Sync resolver created re-imagine op: #{link_msg.body}")
    state
  end

  defp handle_waggle(%{subject: "backup"} = link_msg, state) do
    ghost_id = link_msg.from
    Logger.debug("Backup from ghost #{ghost_id}: #{link_msg.body}")

    backup_data =
      case Jason.decode(link_msg.body) do
        {:ok, data} -> data
        _ -> %{}
      end

    last_checkpoint =
      Map.put(state.last_checkpoint, ghost_id, %{
        at: DateTime.utc_now(),
        data: backup_data
      })

    # Broadcast progress update
    Phoenix.PubSub.broadcast(
      GiTF.PubSub,
      "section:progress",
      {:bee_checkpoint, ghost_id, backup_data}
    )

    %{state | last_checkpoint: last_checkpoint}
  rescue
    _ -> state
  end

  defp handle_waggle(%{subject: "resource_warning"} = link_msg, state) do
    ghost_id = link_msg.from
    Logger.warning("Resource warning from ghost #{ghost_id}: #{link_msg.body}")

    # Broadcast alert
    Phoenix.PubSub.broadcast(
      GiTF.PubSub,
      "section:alerts",
      {:resource_warning, ghost_id, link_msg.body}
    )

    state
  rescue
    _ -> state
  end

  defp handle_waggle(%{subject: "quest_advance"} = link_msg, state) do
    # Handle mission phase advancement requests
    mission_id = link_msg.body

    case GiTF.Major.Orchestrator.advance_quest(mission_id) do
      {:ok, new_phase} ->
        Logger.info("Quest #{mission_id} advanced to #{new_phase} phase")

      {:error, reason} ->
        Logger.warning("Failed to advance mission #{mission_id}: #{inspect(reason)}")
    end

    state
  end

  defp handle_waggle(%{subject: "human_approval"} = link_msg, state) do
    case Jason.decode(link_msg.body) do
      {:ok, %{"action" => "approve", "mission_id" => mission_id} = data} ->
        opts = %{
          approved_by: Map.get(data, "approved_by", link_msg.from),
          notes: Map.get(data, "notes")
        }

        GiTF.Override.approve(mission_id, opts)
        GiTF.Major.Orchestrator.advance_quest(mission_id)

      {:ok, %{"action" => "reject", "mission_id" => mission_id} = data} ->
        reason = Map.get(data, "reason", "Rejected via link_msg")
        rejected_by = Map.get(data, "rejected_by", link_msg.from)
        GiTF.Override.reject(mission_id, reason, %{rejected_by: rejected_by})
        GiTF.Major.Orchestrator.advance_quest(mission_id)

      _ ->
        Logger.warning("Invalid human_approval link_msg body: #{link_msg.body}")
    end

    state
  rescue
    _ -> state
  end

  @clarification_timeout_ms :timer.minutes(15)

  defp handle_waggle(%{subject: "clarification_needed"} = link_msg, state) do
    Logger.warning("Clarification request from ghost #{link_msg.from}: #{link_msg.body}")

    Phoenix.PubSub.broadcast(
      GiTF.PubSub,
      "section:alerts",
      {:clarification_needed, link_msg.from, link_msg.body}
    )

    GiTF.Observability.Alerts.dispatch_webhook(
      :clarification_needed,
      "Ghost #{link_msg.from} needs clarification: #{String.slice(link_msg.body, 0, 200)}"
    )

    # Cancel any previous timer for this ghost, then schedule a new one
    ghost_id = link_msg.from
    old_ref = Map.get(state.clarification_timers, ghost_id)
    if old_ref, do: Process.cancel_timer(old_ref)

    ref =
      Process.send_after(
        self(),
        {:clarification_timeout, ghost_id, link_msg.body},
        @clarification_timeout_ms
      )

    %{state | clarification_timers: Map.put(state.clarification_timers, ghost_id, ref)}
  rescue
    _ -> state
  end

  defp handle_waggle(link_msg, state) do
    Logger.debug("Major received link_msg from #{link_msg.from}: #{link_msg.subject}")
    state
  end

  # -- Private: retry logic ---------------------------------------------------

  defp maybe_retry_job(link_msg, state) do
    case GiTF.Ghosts.get(link_msg.from) do
      {:ok, ghost} when not is_nil(ghost.op_id) ->
        op_id = ghost.op_id
        feedback = link_msg.body

        # Atomic guard: retry_pending is checked+updated in the same GenServer callback
        # (no TOCTOU race since Major is a single process with serialized callbacks)
        if MapSet.member?(state.retry_pending, op_id) or retry_exists?(op_id) do
          Logger.debug("Retry already pending/exists for op #{op_id}, skipping duplicate")
          state
        else
          maybe_retry_job_inner(op_id, feedback, state)
        end

      _ ->
        state
    end
  end

  defp maybe_retry_job_inner(op_id, feedback, state) do
    attempts =
      case GiTF.Ops.get(op_id) do
        {:ok, op} -> Map.get(op, :retry_count, 0)
        _ -> 0
      end

    if attempts < state.max_retries do
      delay_ms = retry_backoff_ms(attempts)

      Logger.info(
        "Scheduling retry for op #{op_id} in #{div(delay_ms, 1000)}s (attempt #{attempts + 1}/#{state.max_retries})"
      )

      Process.send_after(self(), {:delayed_retry, op_id, feedback}, delay_ms)
      %{state | retry_pending: MapSet.put(state.retry_pending, op_id)}
    else
      Logger.warning("Job #{op_id} exhausted #{state.max_retries} retries")
      GiTF.Ops.unblock_dependents(op_id)
      unblock_scout_parent(op_id)
      best_effort_update_quest_status(op_id)
      state
    end
  end

  # Exponential backoff: 30s * 2^attempt with jitter
  # attempt 0 → ~30s, attempt 1 → ~2min, attempt 2 → ~8min
  defp retry_backoff_ms(attempt) do
    base = :timer.seconds(30)
    backoff = base * Integer.pow(4, attempt)
    jitter = :rand.uniform(div(base, 2))
    min(backoff + jitter, :timer.minutes(10))
  end

  defp try_intelligent_retry(op_id, feedback, state) do
    case GiTF.Intel.Retry.retry_with_strategy(op_id, feedback) do
      {:ok, new_job} ->
        case check_quest_budget(new_job.mission_id) do
          :ok ->
            case GiTF.Ghosts.spawn(new_job.id, new_job.sector_id, state.gitf_root) do
              {:ok, _bee} -> {:ok, :intelligent_retry}
              error -> error
            end

          {:error, _} = error ->
            error
        end

      {:error, reason} ->
        Logger.debug("Intelligent retry unavailable for op #{op_id}: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.debug("Intelligent retry crashed for op #{op_id}: #{inspect(e)}")
      {:error, :intelligent_retry_failed}
  end

  defp simple_retry(op_id, feedback, state) do
    case GiTF.Ops.reset(op_id, feedback) do
      {:ok, op} ->
        case check_quest_budget(op.mission_id) do
          :ok ->
            case GiTF.Ghosts.spawn(op_id, op.sector_id, state.gitf_root) do
              {:ok, _bee} ->
                state

              {:error, reason} ->
                Logger.warning("Retry spawn failed for op #{op_id}: #{inspect(reason)}")
                state
            end

          {:error, reason} ->
            Logger.warning(
              "Budget check blocked retry for mission #{op.mission_id}: #{inspect(reason)}"
            )

            GiTF.Link.send(
              "major",
              "major",
              "budget_exceeded",
              "Quest #{op.mission_id} budget blocked (#{inspect(reason)}), op #{op_id} retry skipped"
            )

            state
        end

      {:error, reason} ->
        Logger.warning("Could not reset op #{op_id} for retry: #{inspect(reason)}")
        state
    end
  end

  # -- Private: mission advancement -----------------------------------------------

  defp advance_quest(ghost_id, state) do
    with {:ok, ghost} <- GiTF.Ghosts.get(ghost_id),
         true <- not is_nil(ghost[:op_id]),
         {:ok, op} <- GiTF.Ops.get(ghost[:op_id]) do
      mission_id = op[:mission_id]
      GiTF.Missions.update_status!(mission_id)

      # Try to advance mission through orchestrator
      case GiTF.Major.Orchestrator.advance_quest(mission_id) do
        {:ok, "completed"} ->
          Logger.info("Quest completed: #{mission_id}")

          GiTF.Link.send(
            "system",
            "major",
            "quest_completed",
            "Quest #{mission_id} — all ops done"
          )

          state

        {:ok, _new_phase} ->
          # Orchestrator returned a non-completed phase; check actual mission status
          # in case update_status! already marked it completed (simple missions
          # without the phase system)
          case GiTF.Missions.get(mission_id) do
            {:ok, %{status: "completed"} = mission} ->
              Logger.info("Quest completed: #{mission.name} (#{mission_id})")

              GiTF.Link.send(
                "system",
                "major",
                "quest_completed",
                "Quest \"#{mission.name}\" (#{mission_id}) — all ops done"
              )

              state

            {:ok, mission} ->
              spawn_ready_jobs(mission, state)

            _ ->
              state
          end

        {:error, _reason} ->
          # Fall back to original logic
          case GiTF.Missions.get(mission_id) do
            {:ok, %{status: "completed"} = mission} ->
              Logger.info("Quest completed: #{mission.name} (#{mission_id})")

              GiTF.Link.send(
                "system",
                "major",
                "quest_completed",
                "Quest \"#{mission.name}\" (#{mission_id}) — all ops done"
              )

              state

            {:ok, mission} ->
              spawn_ready_jobs(mission, state)

            _ ->
              state
          end
      end
    else
      _ -> state
    end
  end

  defp best_effort_update_quest_status(op_id) do
    with {:ok, op} <- GiTF.Ops.get(op_id) do
      GiTF.Missions.update_status!(op.mission_id)
    end
  rescue
    _ -> :ok
  end

  defp spawn_ready_jobs(%{status: "planning"}, state), do: state

  defp spawn_ready_jobs(%{status: status}, state)
       when status in ["killed", "completed", "closed"], do: state

  defp spawn_ready_jobs(mission, state) do
    # Pre-flight health gate — don't spawn into a degraded system
    case preflight_health_check() do
      {:degraded, reasons} ->
        Logger.warning(
          "Spawn gate: system degraded (#{Enum.join(reasons, ", ")}), skipping spawn cycle"
        )

        state

      :ok ->
        do_spawn_ready_jobs(mission, state)
    end
  end

  defp do_spawn_ready_jobs(mission, state) do
    # Per-provider circuit breakers handle routing/fallback — no global gate needed.
    # Check budget proactively before spawning
    case check_quest_budget(mission.id) do
      {:error, reason} ->
        Logger.warning("Budget check blocked spawn for mission #{mission.id}: #{inspect(reason)}")
        state

      :ok ->
        pending_jobs =
          for op <- mission.ops,
              op.status == "pending",
              GiTF.Ops.ready?(op.id),
              do: op

        active_count = GiTF.Ghosts.list(status: GhostStatus.working()) |> length()
        available_slots = max(state.effective_max_ghosts - active_count, 0)
        stagger_delay = GiTF.Config.Provider.get([:major, :stagger_delay_ms], 2000)

        jobs_to_spawn =
          Enum.take(pending_jobs, available_slots)
          |> filter_file_overlaps(mission)

        # Ensure an active run exists for this mission when spawning ops
        run = ensure_active_run(mission.id, jobs_to_spawn)

        jobs_to_spawn
        |> Enum.with_index()
        |> Enum.reduce(state, fn {op, idx}, acc ->
          # Stagger: sleep before every spawn except the first
          if idx > 0 and stagger_delay > 0, do: Process.sleep(stagger_delay)

          # Triage before spawning
          {complexity, pipeline} = GiTF.Triage.triage(op)
          triage_store_job(op, complexity, pipeline)

          # If complex and no recon exists yet, create one and skip spawning the parent.
          # Skip recon for ops that are already recons or phase jobs (research, requirements, etc.)
          already_recon? = Map.get(op, :recon, false)
          phase_job? = Map.get(op, :phase_job, false)

          if complexity == :complex and not already_recon? and not phase_job? and
               GiTF.Recon.should_scout?(op) and not scout_exists?(op.id) do
            case GiTF.Recon.create_scout_job(op.id, op.sector_id) do
              {:ok, scout_job} ->
                Logger.info("Created recon for complex op #{op.id}, deferring spawn")
                # Spawn the recon op instead
                spawn_single_job(scout_job, acc, run)

              {:error, reason} ->
                Logger.warning(
                  "Failed to create recon for op #{op.id}: #{inspect(reason)}, spawning directly"
                )

                spawn_single_job(op, acc, run)
            end
          else
            spawn_single_job(op, acc, run)
          end
        end)
    end
  end

  defp preflight_health_check do
    checks = [
      {:store, GiTF.Observability.Health.ready?()},
      {:disk, check_disk_ok()},
      {:git, check_git_ok()}
    ]

    failed = for {name, ok?} <- checks, !ok?, do: name

    if failed == [] do
      :ok
    else
      {:degraded, Enum.map(failed, &to_string/1)}
    end
  rescue
    _ -> :ok
  end

  defp check_disk_ok do
    case GiTF.gitf_dir() do
      {:ok, gitf_root} ->
        # Quick check: can we write a temp file?
        probe = Path.join([gitf_root, ".gitf", ".health_probe"])

        case File.write(probe, "ok") do
          :ok ->
            File.rm(probe)
            true

          {:error, _} ->
            false
        end

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp check_git_ok do
    case GiTF.Archive.all(:sectors) |> List.first() do
      nil ->
        true

      sector ->
        if sector.path && File.dir?(sector.path) do
          case GiTF.Git.safe_cmd(["status", "--porcelain"],
                 cd: sector.path,
                 stderr_to_stdout: true
               ) do
            {_, 0} -> true
            _ -> false
          end
        else
          true
        end
    end
  rescue
    _ -> true
  end

  defp check_quest_budget(mission_id) do
    case GiTF.Budget.check(mission_id) do
      {:ok, _remaining} -> :ok
      {:error, :budget_exceeded, _spent} -> {:error, :budget_exceeded}
    end
  rescue
    e ->
      # Fail-closed: if we can't verify the budget, don't spawn.
      # This prevents runaway costs when Archive is unavailable during recovery.
      Logger.warning(
        "Budget check failed for mission #{mission_id}: #{Exception.message(e)} — blocking spawn"
      )

      {:error, :budget_check_failed}
  end

  # -- Private: file overlap guard ---------------------------------------------

  defp filter_file_overlaps(candidates, mission) do
    # Get target_files of all currently running (non-phase) ops for this mission
    running_files =
      for op <- mission.ops,
          op.status in ["running", "assigned"] and not (op[:phase_job] || false),
          file <- op[:target_files] || [],
          into: MapSet.new(),
          do: file

    if MapSet.size(running_files) == 0 do
      candidates
    else
      Enum.filter(candidates, fn op ->
        op_files = MapSet.new(op[:target_files] || [])
        overlap = MapSet.intersection(op_files, running_files)

        if MapSet.size(overlap) > 0 do
          Logger.info(
            "Deferring op #{op.id}: target files overlap with running op (#{Enum.join(overlap, ", ")})"
          )

          GiTF.Telemetry.emit(
            [:gitf, :conflict, :prevented],
            %{},
            %{op_id: op.id, mission_id: mission.id, overlapping_files: MapSet.to_list(overlap)}
          )

          false
        else
          true
        end
      end)
    end
  end

  # -- Private: triage helpers -------------------------------------------------

  defp triage_store_job(op, complexity, pipeline) do
    case GiTF.Ops.get(op.id) do
      {:ok, current} ->
        updated = %{current | triage_result: %{complexity: complexity, pipeline: pipeline}}
        GiTF.Archive.put(:ops, updated)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp scout_exists?(parent_op_id) do
    GiTF.Archive.filter(:ops, fn j ->
      Map.get(j, :scout_for) == parent_op_id
    end)
    |> Enum.any?()
  rescue
    _ -> false
  end

  defp retry_exists?(op_id) do
    GiTF.Archive.find_one(:ops, fn j ->
      Map.get(j, :retry_of) == op_id
    end) != nil
  rescue
    _ -> false
  end

  defp spawn_single_job(op, state, run) do
    if GiTF.Distributed.clustered?() do
      GiTF.Distributed.spawn_on_cluster(fn ->
        GiTF.Ghosts.spawn_detached(op.id, op.sector_id, state.gitf_root)
      end)

      Logger.info("Dispatched distributed spawn for op #{op.id}")
      state
    else
      case GiTF.Ghosts.spawn_detached(op.id, op.sector_id, state.gitf_root) do
        {:ok, ghost} ->
          Logger.info("Auto-spawned ghost #{ghost.id} for op #{op.id} (#{op.title})")
          register_with_run(run, ghost.id, op.id)

          # Monitor the worker process for immediate failure detection
          # (supplements the timer-based recover_stuck_jobs)
          monitor_ghost_worker(ghost.id)

          state

        {:error, reason} ->
          {step, raw_reason} =
            case reason do
              {s, r} when is_atom(s) -> {s, r}
              other -> {nil, other}
            end

          Logger.warning(
            "Failed to auto-spawn ghost for op #{op.id} (step: #{inspect(step)}): #{inspect(raw_reason)}"
          )

          GiTF.Telemetry.emit([:gitf, :ghost, :spawn_failed], %{}, %{
            op_id: op.id,
            sector_id: op.sector_id,
            step: step,
            reason: inspect(raw_reason)
          })

          state
      end
    end
  end

  defp handle_ghost_death(ghost_id, state) do
    case GiTF.Ghosts.get(ghost_id) do
      {:ok, %{status: GhostStatus.restarting()}} ->
        Logger.info(
          "Ghost #{ghost_id} is auto-resuming via supervisor, skipping failure handling"
        )

        state

      {:ok, %{status: status, op_id: op_id}}
      when status in [GhostStatus.working(), GhostStatus.starting()] and not is_nil(op_id) ->
        if MapSet.member?(state.recovery_pending, ghost_id) do
          state
        else
          Process.send_after(self(), {:check_ghost_recovery, ghost_id, op_id}, 5_000)
          %{state | recovery_pending: MapSet.put(state.recovery_pending, ghost_id)}
        end

      _ ->
        state
    end
  end

  defp monitor_ghost_worker(ghost_id) do
    case GiTF.Ghost.Worker.lookup(ghost_id) do
      {:ok, pid} -> Process.monitor(pid)
      :error -> nil
    end
  end

  # -- Private: post-review checks --------------------------------------------

  @debrief_interval :timer.minutes(5)

  defp schedule_debrief_check do
    Process.send_after(self(), :check_debriefs, @debrief_interval)
  end

  defp check_debriefs do
    # Each review check runs async so validation commands (up to 120s) and
    # auto-revert (which acquires the sector lock) don't block Major's mailbox.
    GiTF.Debrief.active_reviews()
    |> Enum.each(fn review ->
      Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
        process_debrief_review(review)
      end)
    end)
  rescue
    e ->
      Logger.warning("Post-review check failed: #{Exception.message(e)}")
  end

  defp process_debrief_review(review) do
    if GiTF.Debrief.expired?(review) do
      Logger.info("Post-review expired for mission #{review.mission_id}, closing")
      GiTF.Debrief.close_review(review.mission_id)
    else
      case GiTF.Debrief.check_regressions(review.mission_id) do
        {:ok, :regression, findings} ->
          GiTF.Debrief.handle_regression(review.mission_id, findings)

        _ ->
          :ok
      end
    end
  rescue
    e ->
      Logger.warning(
        "Debrief review for mission #{review.mission_id} failed: #{Exception.message(e)}"
      )
  end

  # -- Private: stall detection ------------------------------------------------

  @stall_check_interval :timer.minutes(2)
  @stuck_recovery_interval :timer.minutes(5)
  @phase_advancement_interval :timer.minutes(3)
  @janitor_interval :timer.minutes(15)
  @autoscale_interval :timer.seconds(60)

  defp schedule_stall_check do
    Process.send_after(self(), :check_stalls, @stall_check_interval)
  end

  defp schedule_stuck_recovery do
    Process.send_after(self(), :recover_stuck, @stuck_recovery_interval)
  end

  defp schedule_phase_advancement do
    Process.send_after(self(), :advance_stuck_phases, @phase_advancement_interval)
  end

  defp schedule_janitor do
    Process.send_after(self(), :janitor_run, @janitor_interval)
  end

  defp schedule_autoscale do
    Process.send_after(self(), :autoscale_check, @autoscale_interval)
  end

  # Computes the scaling decision off-GenServer so the Archive + costs scan
  # doesn't block the Major mailbox, then casts the result back.
  defp dispatch_autoscale(max_ghosts) do
    major = self()

    Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
      try do
        {target, meta} = GiTF.Autonomy.compute_scaling_decision(max_ghosts)
        GenServer.cast(major, {:apply_autoscale, target, meta})
      rescue
        e -> Logger.warning("Autoscale check failed: #{Exception.message(e)}")
      end
    end)
  end

  defp apply_autoscale(state, target, meta) do
    if target == state.effective_max_ghosts do
      state
    else
      Logger.info(
        "Autoscale: effective ghost cap #{state.effective_max_ghosts} → #{target} " <>
          "(#{meta.reason}, max_util=#{Float.round(meta.max_util, 2)})"
      )

      GiTF.Telemetry.emit(
        [:gitf, :major, :autoscaled],
        %{old: state.effective_max_ghosts, new: target, max_util: meta.max_util},
        %{reason: meta.reason}
      )

      %{state | effective_max_ghosts: target}
    end
  end

  defp resume_active_quests(_state) do
    # On startup, find active missions with no running ops or phase ghosts and kick them
    active_quests =
      GiTF.Archive.all(:missions)
      |> Enum.filter(fn q ->
        q[:status] not in [nil, "completed", "failed", "cancelled", "paused"] and
          q[:current_phase] not in [nil, "completed", "failed", "cancelled"]
      end)

    Enum.each(active_quests, fn mission ->
      quest_jobs =
        GiTF.Archive.filter(:ops, fn j ->
          j.mission_id == mission.id and j.status in ["running", "assigned", "pending"]
        end)

      if Enum.empty?(quest_jobs) do
        Logger.info(
          "Resuming stalled mission #{mission.id} (phase: #{mission[:current_phase]}, no active ops)"
        )

        GiTF.Major.Orchestrator.advance_quest(mission.id)
      end
    end)
  rescue
    e ->
      Logger.warning("Quest resumption failed: #{Exception.message(e)}")
  end

  defp advance_stuck_mission_phases do
    # Periodically call advance_quest for missions in non-terminal phases.
    # This catches cases where a phase ghost completed but the link_msg was lost.
    phase_statuses = [
      "research",
      "requirements",
      "design",
      "review",
      "planning",
      "implementation",
      "validation",
      "awaiting_approval",
      "sync",
      "simplify",
      "scoring"
    ]

    GiTF.Archive.all(:missions)
    |> Enum.filter(fn q ->
      q[:status] in phase_statuses or q[:current_phase] in phase_statuses
    end)
    |> Enum.each(fn mission ->
      current_phase = mission[:current_phase]

      case GiTF.Major.Orchestrator.advance_quest(mission.id) do
        {:ok, new_phase} ->
          if new_phase != current_phase do
            Logger.info("Periodic phase check advanced mission #{mission.id} to #{new_phase}")
          end

        _ ->
          :ok
      end
    end)
  rescue
    e ->
      Logger.warning("Phase advancement check failed: #{Exception.message(e)}")
  end

  @doc false
  def detect_stalled_bees(state) do
    now = DateTime.utc_now()
    base_stall_seconds = div(state.stall_timeout, 1000)

    working_bees = GiTF.Ghosts.list(status: GhostStatus.working())

    Enum.each(working_bees, fn ghost ->
      last_cp = Map.get(state.last_checkpoint, ghost.id)

      # Use backup time if available, otherwise use ghost's inserted_at
      reference_time =
        if last_cp, do: last_cp.at, else: ghost.inserted_at

      seconds_since = DateTime.diff(now, reference_time, :second)

      # Scale stall timeout with op complexity
      stall_seconds = adaptive_stall_timeout(ghost, base_stall_seconds)

      if seconds_since > stall_seconds * 2 do
        # Double the stall threshold = hard-fail the ghost
        Logger.warning(
          "Hard-stall: ghost #{ghost.id} unresponsive for #{seconds_since}s, failing op"
        )

        # Kill the worker process if it exists
        case GiTF.Ghost.Worker.lookup(ghost.id) do
          {:ok, pid} -> Process.exit(pid, :kill)
          :error -> :ok
        end

        # Fail the op so retry logic picks it up
        if ghost.op_id do
          GiTF.Ops.fail(ghost.op_id)
          notify_run_job_failed(ghost.op_id)

          link_msg = %{
            from: ghost.id,
            subject: "stall_timeout",
            body: "Ghost stalled for #{seconds_since}s without backup. Auto-failed for retry."
          }

          maybe_retry_job(link_msg, state)
        end

        GiTF.Archive.put(:ghosts, %{ghost | status: GhostStatus.crashed()})
      else
        if seconds_since > stall_seconds do
          Logger.warning(
            "Stall detected: ghost #{ghost.id} has not reported in #{seconds_since}s " <>
              "(threshold: #{stall_seconds}s)"
          )

          Phoenix.PubSub.broadcast(
            GiTF.PubSub,
            "section:alerts",
            {:stall_warning, ghost.id, seconds_since}
          )
        end
      end
    end)
  rescue
    _ -> :ok
  end

  # -- Private: periodic op spawning ------------------------------------------

  @job_spawn_interval :timer.seconds(15)

  defp schedule_job_spawner do
    Process.send_after(self(), :spawn_ready_jobs, @job_spawn_interval)
  end

  @actionable_statuses ~w(active pending planning research implementation awaiting_approval)

  defp spawn_all_ready_jobs(state) do
    # Pre-flight health gate — don't spawn into a degraded system
    case preflight_health_check() do
      {:degraded, reasons} ->
        Logger.warning(
          "Spawn gate: system degraded (#{Enum.join(reasons, ", ")}), skipping spawn cycle"
        )

        state

      :ok ->
        do_priority_spawn_cycle(state)
    end
  rescue
    e ->
      Logger.warning("Job spawner error: #{Exception.message(e)}")
      state
  end

  # Global priority-sorted scheduling: collects all pending-ready ops across
  # all eligible missions, sorts by effective priority, and fills ghost slots
  # in priority order with hold-back for low-priority work.
  defp do_priority_spawn_cycle(state) do
    missions = GiTF.Archive.all(:missions)
    all_ops = GiTF.Archive.all(:ops)
    all_deps = GiTF.Archive.all(:op_dependencies)

    # Build lookup maps once to avoid N+1 Archive scans in the hot path
    mission_map =
      missions
      |> Enum.filter(&(&1[:status] in @actionable_statuses))
      |> Map.new(&{&1.id, &1})

    ops_by_id = Map.new(all_ops, &{&1.id, &1})
    deps_by_op = Enum.group_by(all_deps, & &1.op_id)

    # Resolve deadlocks before collecting ops
    Enum.each(mission_map, fn {mission_id, _mission} ->
      case GiTF.Resilience.detect_deadlock(mission_id) do
        {:error, {:deadlock, cycles}} ->
          Logger.warning("Deadlock in mission #{mission_id}, auto-resolving")
          GiTF.Resilience.resolve_deadlock(mission_id, cycles)

        _ ->
          :ok
      end
    end)

    # Collect all pending-and-ready ops using pre-loaded dependency data
    pending_ops =
      all_ops
      |> Enum.filter(fn op ->
        op.status == "pending" and
          Map.has_key?(mission_map, op[:mission_id]) and
          GiTF.Ops.ready?(op.id, deps_by_op, ops_by_id)
      end)

    if pending_ops == [] do
      state
    else
      # Annotate each op with its mission's effective priority and sort
      annotated =
        pending_ops
        |> Enum.map(fn op ->
          mission = mission_map[op.mission_id]
          eff_priority = GiTF.Priority.effective_priority(mission)
          {op, mission, eff_priority}
        end)
        |> Enum.sort_by(fn {_op, mission, eff_priority} ->
          {GiTF.Priority.weight(eff_priority), Map.get(mission, :inserted_at, DateTime.utc_now())}
        end)

      # Hold-back: if any high-priority work is pending, suppress low/background ops
      has_high_priority =
        Enum.any?(annotated, fn {_op, _m, eff} -> GiTF.Priority.high_priority?(eff) end)

      {candidates, held_back} =
        if has_high_priority do
          Enum.split_with(annotated, fn {_op, _m, eff} ->
            not GiTF.Priority.hold_back?(eff)
          end)
        else
          {annotated, []}
        end

      if held_back != [] do
        Logger.info(
          "Priority hold-back: suppressing #{length(held_back)} low-priority ops while high-priority work is pending"
        )
      end

      # Compute available slots
      active_count = GiTF.Ghosts.list(status: GhostStatus.working()) |> length()
      available_slots = max(state.effective_max_ghosts - active_count, 0)
      stagger_delay = GiTF.Config.Provider.get([:major, :stagger_delay_ms], 2000)

      # Pre-compute running files per mission (avoids re-scanning all_ops per candidate)
      running_files_by_mission = precompute_running_files(all_ops)

      # Pre-compute budget status per mission (avoids repeated Archive scans)
      budget_cache =
        mission_map
        |> Map.keys()
        |> Map.new(fn mid -> {mid, check_quest_budget(mid)} end)

      # Take up to available_slots, filtering file overlaps and budget
      {ops_to_spawn, _} =
        Enum.reduce(candidates, {[], MapSet.new()}, fn {op, mission, _eff},
                                                       {selected, selected_files} ->
          if length(selected) >= available_slots do
            {selected, selected_files}
          else
            budget_ok = budget_cache[mission.id] == :ok

            # File overlap check against running ops + already-selected ops
            op_files = MapSet.new(op[:target_files] || [])
            mission_running = Map.get(running_files_by_mission, mission.id, MapSet.new())
            all_blocked = MapSet.union(selected_files, mission_running)
            overlap = MapSet.intersection(op_files, all_blocked)

            if budget_ok and MapSet.size(overlap) == 0 do
              {[{op, mission} | selected], MapSet.union(selected_files, op_files)}
            else
              {selected, selected_files}
            end
          end
        end)

      ops_to_spawn = Enum.reverse(ops_to_spawn)

      # Spawn each selected op with triage + recon logic
      Enum.with_index(ops_to_spawn)
      |> Enum.reduce(state, fn {{op, mission}, idx}, acc ->
        if idx > 0 and stagger_delay > 0, do: Process.sleep(stagger_delay)

        {complexity, pipeline} = GiTF.Triage.triage(op)
        triage_store_job(op, complexity, pipeline)

        already_recon? = Map.get(op, :recon, false)
        phase_job? = Map.get(op, :phase_job, false)

        run = ensure_active_run(mission.id, [op])

        if complexity == :complex and not already_recon? and not phase_job? and
             GiTF.Recon.should_scout?(op) and not scout_exists?(op.id) do
          case GiTF.Recon.create_scout_job(op.id, op.sector_id) do
            {:ok, scout_job} ->
              Logger.info("Created recon for complex op #{op.id}, deferring spawn")
              spawn_single_job(scout_job, acc, run)

            {:error, reason} ->
              Logger.warning(
                "Failed to create recon for op #{op.id}: #{inspect(reason)}, spawning directly"
              )

              spawn_single_job(op, acc, run)
          end
        else
          spawn_single_job(op, acc, run)
        end
      end)
    end
  end

  # Pre-compute running/assigned file sets per mission (single pass over all_ops)
  defp precompute_running_files(all_ops) do
    all_ops
    |> Enum.filter(fn op ->
      op.status in ["running", "assigned"] and not Map.get(op, :phase_job, false)
    end)
    |> Enum.group_by(& &1[:mission_id])
    |> Map.new(fn {mid, ops} ->
      {mid, ops |> Enum.flat_map(&(&1[:target_files] || [])) |> MapSet.new()}
    end)
  end

  # -- Private: link_msg recovery ------------------------------------------------

  defp schedule_waggle_recovery do
    Process.send_after(self(), :schedule_waggle_recovery, @waggle_recovery_interval)
  end

  defp recover_missed_waggles(state) do
    cutoff = DateTime.shift(DateTime.utc_now(), second: -@waggle_stale_seconds)

    unread =
      GiTF.Link.list(to: "major", read: false)
      |> Enum.filter(fn w ->
        DateTime.compare(w.inserted_at, cutoff) == :lt
      end)

    Enum.reduce(unread, state, fn link_msg, acc ->
      Logger.info("Recovering missed link_msg: #{link_msg.subject} from #{link_msg.from}")
      GiTF.Link.mark_read(link_msg.id)

      try do
        handle_waggle(link_msg, acc)
      rescue
        e ->
          Logger.warning(
            "Failed to process recovered link_msg #{link_msg.id} (#{link_msg.subject}): #{Exception.message(e)}"
          )

          acc
      end
    end)
  rescue
    e ->
      Logger.warning("Link recovery failed: #{Exception.message(e)}")
      state
  end

  # -- Private: Claude session management ------------------------------------

  defp launch_claude_session(state) do
    if GiTF.Runtime.ModelResolver.api_mode?() do
      launch_api_session(state)
    else
      launch_cli_session(state)
    end
  end

  defp launch_cli_session(state) do
    queen_workspace = queen_workspace_path(state.gitf_root)

    with :ok <- File.mkdir_p(queen_workspace),
         :ok <- setup_sparse_checkout(queen_workspace, state.gitf_root),
         :ok <- maybe_generate_settings(:major, state.gitf_root, queen_workspace) do
      GiTF.Runtime.Models.spawn_interactive(queen_workspace)
    end
  end

  defp launch_api_session(state) do
    queen_workspace = queen_workspace_path(state.gitf_root)
    File.mkdir_p!(queen_workspace)

    # In API mode, start an agent loop task with queen tools
    task =
      Task.async(fn ->
        GiTF.Runtime.AgentLoop.run(
          "You are the Major orchestrator for a GiTF of AI coding agents. " <>
            "Monitor active missions, manage ghost workers, and coordinate work.",
          queen_workspace,
          tool_set: :major,
          max_iterations: 200,
          model: GiTF.Runtime.ModelResolver.resolve("opus")
        )
      end)

    {:ok, task}
  end

  defp setup_sparse_checkout(queen_workspace, gitf_root) do
    if GiTF.Git.repo?(gitf_root) do
      case GiTF.Git.sparse_checkout_init(queen_workspace) do
        :ok ->
          case GiTF.Git.sparse_checkout_set(queen_workspace, [".gitf"]) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning("Sparse checkout set failed: #{reason}")
              :ok
          end

        {:error, reason} ->
          Logger.warning("Sparse checkout init failed: #{reason}")
          :ok
      end
    else
      :ok
    end
  end

  defp queen_workspace_path(gitf_root) do
    Path.join([gitf_root, ".gitf", "major"])
  end

  defp maybe_generate_settings(:major, gitf_root, workspace) do
    case GiTF.Runtime.Models.workspace_setup("major", gitf_root) do
      nil ->
        :ok

      settings ->
        claude_dir = Path.join(workspace, ".claude")
        settings_path = Path.join(claude_dir, "settings.json")

        with :ok <- File.mkdir_p(claude_dir),
             json = Jason.encode!(settings, pretty: true),
             :ok <- File.write(settings_path, json) do
          :ok
        end
    end
  end

  defp find_job_for_bee(ghost_id) do
    case GiTF.Ghosts.get(ghost_id) do
      {:ok, ghost} -> ghost.op_id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp extract_op_id_from_body(body) when is_binary(body) do
    case Regex.run(~r/Job ([\w-]+)/, body) do
      [_, op_id] -> op_id
      _ -> nil
    end
  end

  defp extract_op_id_from_body(_), do: nil

  defp reimagine_conflicted_job(shell_id, link_msg, state) do
    op_id = find_job_for_bee(link_msg.from)

    if op_id do
      Logger.info("Reimagining conflicted op #{op_id} (shell #{inspect(shell_id)})")
      GiTF.Ops.fail(op_id)

      cell_info = if shell_id, do: "on shell #{shell_id}", else: "no shell"

      conflict_waggle = %{
        from: link_msg.from,
        subject: "merge_conflict",
        body:
          "Sync conflict #{cell_info}: #{link_msg.body}. " <>
            "Redo the work avoiding conflicting file regions."
      }

      maybe_retry_job(conflict_waggle, state)
    else
      Logger.warning("Could not reimagine: no op found for ghost #{link_msg.from}")
      state
    end
  rescue
    e ->
      Logger.warning("Reimagine failed for shell #{inspect(shell_id)}: #{Exception.message(e)}")
      state
  end

  # Scale stall timeout based on op complexity:
  # simple = 1x (10 min default), moderate = 2x (20 min), complex = 4x (40 min)
  defp adaptive_stall_timeout(ghost, base_seconds) do
    multiplier =
      case ghost.op_id do
        nil ->
          1

        op_id ->
          case GiTF.Ops.get(op_id) do
            {:ok, op} ->
              case Map.get(op, :triage_result) do
                %{complexity: :complex} ->
                  4

                %{complexity: :moderate} ->
                  2

                _ ->
                  # Also check string complexity from classifier
                  case Map.get(op, :complexity) do
                    c when c in ["high", "critical"] -> 4
                    "moderate" -> 2
                    _ -> 1
                  end
              end

            _ ->
              1
          end
      end

    base_seconds * multiplier
  rescue
    _ -> base_seconds
  end

  defp unblock_scout_parent(op_id) do
    case GiTF.Ops.get(op_id) do
      {:ok, %{recon: true, scout_for: parent_id}} when is_binary(parent_id) ->
        Logger.info("Recon op #{op_id} exhausted retries, unblocking parent #{parent_id}")
        GiTF.Ops.unblock_dependents(op_id)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp read_max_ghosts(gitf_root) do
    config_path = Path.join([gitf_root, ".gitf", "config.toml"])

    case GiTF.Config.read_config(config_path) do
      {:ok, config} -> get_in(config, ["major", "max_ghosts"]) || 5
      {:error, _} -> 5
    end
  end

  # -- Private: run management ------------------------------------------------

  defp ensure_active_run(mission_id, jobs_to_spawn) do
    case GiTF.Run.active_for_quest(mission_id) do
      nil ->
        op_ids = Enum.map(jobs_to_spawn, & &1.id)
        {:ok, run} = GiTF.Run.create(mission_id, op_ids: op_ids)
        Logger.info("Created run #{run.id} for mission #{mission_id} with #{length(op_ids)} ops")
        run

      run ->
        # Add any new ops that aren't already tracked
        Enum.each(jobs_to_spawn, fn op ->
          if op.id not in run.op_ids do
            GiTF.Run.add_job(run.id, op.id)
          end
        end)

        run
    end
  rescue
    e ->
      Logger.warning("Failed to ensure active run for mission #{mission_id}: #{inspect(e)}")
      nil
  end

  defp register_with_run(nil, _ghost_id, _op_id), do: :ok

  defp register_with_run(run, ghost_id, op_id) do
    GiTF.Run.add_bee(run.id, ghost_id)

    if op_id not in run.op_ids do
      GiTF.Run.add_job(run.id, op_id)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp notify_run_job_completed(op_id) do
    mission_id = job_mission_id(op_id)

    if mission_id do
      case GiTF.Run.active_for_quest(mission_id) do
        nil ->
          :ok

        run ->
          case GiTF.Run.job_completed(run.id, op_id) do
            {:ok, _run, :run_complete} ->
              Logger.info("Run #{run.id} complete for mission #{mission_id}")

            {:ok, _run} ->
              :ok

            {:error, _} ->
              :ok
          end
      end
    end
  rescue
    _ -> :ok
  end

  defp notify_run_job_failed(op_id) do
    mission_id = job_mission_id(op_id)

    if mission_id do
      case GiTF.Run.active_for_quest(mission_id) do
        nil ->
          :ok

        run ->
          case GiTF.Run.job_failed(run.id, op_id) do
            {:ok, _run, :run_complete} ->
              Logger.info("Run #{run.id} complete (with failures) for mission #{mission_id}")

            {:ok, _run} ->
              :ok

            {:error, _} ->
              :ok
          end
      end
    end
  rescue
    _ -> :ok
  end

  defp job_mission_id(op_id) do
    case GiTF.Ops.get(op_id) do
      {:ok, op} -> op[:mission_id]
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
