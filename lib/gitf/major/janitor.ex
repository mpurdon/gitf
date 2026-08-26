defmodule GiTF.Major.Janitor do
  @moduledoc """
  Periodic recovery and maintenance agent for `GiTF.Major`.

  The Janitor is a sibling GenServer to Major that owns all periodic timers
  for stall detection, stuck-op recovery, debrief checks, phase advancement,
  link recovery, and the idle code-quality sweeper. It runs under the same
  supervisor as Major with a `:one_for_one` strategy, so a Janitor crash
  does not take Major down — link routing keeps working even if recovery
  is temporarily broken.

  ## Why a separate process?

  Major handles real-time link delivery; recovery work is bursty and can
  involve Archive scans across hundreds of records. Isolating it here:

    * Keeps Major's mailbox responsive to live link traffic
    * Lets recovery code crash and restart without disrupting the factory
    * Makes the supervision boundary between "hot path" and "background
      maintenance" explicit

  ## Communication model

    * Read-only access to Major state goes through `GiTF.Major.get_stall_state/0`
    * State mutations are sent as casts to Major (e.g. `{:trigger_retry, _}`,
      `:recover_missed_waggles`) so Major remains the single writer of its
      own state
    * Pure Archive/Orchestrator operations happen in-process here

  ## Timers

  All intervals come from `Application.get_env(:gitf, :timeouts)`:

    * `:check_stalls` — `:stall_check_interval_ms` (default 2 min)
    * `:recover_stuck` — `:stuck_recovery_interval_ms` (default 5 min)
    * `:check_debriefs` — `:debrief_interval_ms` (default 5 min)
    * `:advance_stuck_phases` — `:phase_advancement_interval_ms` (default 3 min)
    * `:janitor_run` — `:janitor_interval_ms` (default 15 min)
    * `:schedule_waggle_recovery` — `:waggle_recovery_interval_ms` (default 30 s)
  """

  use GenServer
  require Logger

  require GiTF.Ghost.Status, as: GhostStatus

  @name __MODULE__

  # Hard-stall reap bound for a ghost whose OS process is still ALIVE: 6x
  # the (already adaptive) stall threshold — with the default 600s base
  # that's 60 minutes, past any sane npm ci or cargo build but still short
  # enough to break a genuine spin. Dead processes keep the 2x bound.
  @os_alive_hard_stall_multiplier 6

  # -- Client API ------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  # -- GenServer callbacks ---------------------------------------------------

  @impl true
  def init(_opts) do
    Logger.debug("Major.Janitor initialized")
    {:ok, %{}, {:continue, :prime_recovery}}
  end

  @impl true
  def handle_continue(:prime_recovery, state) do
    if autonomous?() do
      # Eager recovery on startup, mirroring what Major's init used to do.
      # Stuck-op recovery first so any orphaned ops are cleared before we
      # process backlogged links.
      safe(&recover_stuck_jobs/0, "stuck op recovery (startup)")
      send(self(), :recover_missed_waggles)

      schedule(:schedule_waggle_recovery, :waggle_recovery_interval_ms, 30_000)
      schedule(:check_stalls, :stall_check_interval_ms, 2 * 60 * 1_000)
      schedule(:recover_stuck, :stuck_recovery_interval_ms, 5 * 60 * 1_000)
      schedule(:check_debriefs, :debrief_interval_ms, 5 * 60 * 1_000)
      schedule(:advance_stuck_phases, :phase_advancement_interval_ms, 3 * 60 * 1_000)
      schedule(:janitor_run, :janitor_interval_ms, 15 * 60 * 1_000)
      schedule(:maintain_caches, :cache_maintenance_interval_ms, 6 * 60 * 60 * 1_000)
    end

    {:noreply, state}
  end

  # The test env sets this false: the Core supervisor restarts whenever a
  # test swaps the Archive, and each restart re-primed recovery — which then
  # asynchronously advanced missions *other tests* had created (completing
  # them, starting debrief reviews, spawning ghosts) and made global-count
  # assertions flaky. The module was always designed for tests to drive its
  # functions directly; this flag just makes the timers honor that.
  defp autonomous? do
    Application.get_env(:gitf, :janitor_autonomous, true)
  end

  @impl true
  def handle_info(:recover_missed_waggles, state) do
    GenServer.cast(GiTF.Major, :recover_missed_waggles)
    {:noreply, state}
  end

  def handle_info(:schedule_waggle_recovery, state) do
    GenServer.cast(GiTF.Major, :recover_missed_waggles)
    schedule(:schedule_waggle_recovery, :waggle_recovery_interval_ms, 30_000)
    {:noreply, state}
  end

  # Shared build caches need an owner: unmaintained, a corrupt npm cache
  # silently poisons every validation (runs 21/27/30) and a cargo target
  # dir grows until the disk fills (2026-08-19). Verify, repair, GC.
  def handle_info(:maintain_caches, state) do
    safe(fn -> GiTF.Infra.CacheLifecycle.maintain() end, "cache maintenance")
    schedule(:maintain_caches, :cache_maintenance_interval_ms, 6 * 60 * 60 * 1_000)
    {:noreply, state}
  end

  def handle_info(:check_stalls, state) do
    safe(&detect_stalled_bees/0, "stall detection")
    schedule(:check_stalls, :stall_check_interval_ms, 2 * 60 * 1_000)
    {:noreply, state}
  end

  def handle_info(:recover_stuck, state) do
    safe(&recover_stuck_jobs/0, "stuck op recovery")
    safe(&timeout_stale_jobs/0, "stale op timeout")
    schedule(:recover_stuck, :stuck_recovery_interval_ms, 5 * 60 * 1_000)
    {:noreply, state}
  end

  def handle_info(:check_debriefs, state) do
    safe(&check_debriefs/0, "debrief check")
    schedule(:check_debriefs, :debrief_interval_ms, 5 * 60 * 1_000)
    {:noreply, state}
  end

  def handle_info(:advance_stuck_phases, state) do
    safe(&advance_stuck_mission_phases/0, "phase advancement")
    schedule(:advance_stuck_phases, :phase_advancement_interval_ms, 3 * 60 * 1_000)
    {:noreply, state}
  end

  def handle_info(:janitor_run, state) do
    safe(&GiTF.Major.IdleSweeper.run_if_idle/0, "idle sweeper")
    schedule(:janitor_run, :janitor_interval_ms, 15 * 60 * 1_000)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Major.Janitor received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # -- Private: scheduling ---------------------------------------------------

  defp schedule(msg, key, default_ms) do
    interval = Application.get_env(:gitf, :timeouts, [])[key] || default_ms
    Process.send_after(self(), msg, interval)
  end

  # Wrap a maintenance pass so a transient failure (e.g. Archive contention)
  # doesn't crash the Janitor and skip the next scheduled tick.
  defp safe(fun, label) do
    fun.()
  rescue
    e -> Logger.warning("#{label} failed: #{Exception.message(e)}")
  end

  # -- Private: stuck op recovery --------------------------------------------

  defp recover_stuck_jobs do
    stuck_jobs =
      GiTF.Archive.by_index(:ops, :status, "running") ++
        GiTF.Archive.by_index(:ops, :status, "assigned")

    Enum.each(stuck_jobs, fn op ->
      if !worker_alive?(op.ghost_id) do
        Logger.warning("Recovering stuck op #{op.id} (status #{op.status}, worker dead)")
        GiTF.Ops.fail(op.id)

        # Trigger retry via delayed_retry on Major (same path as link-based failures).
        # The retry timer must fire on Major's mailbox, not the Janitor's.
        if !retry_exists?(op.id) do
          send(GiTF.Major, {:delayed_retry, op.id, "Worker process died unexpectedly"})
        end
      end
    end)

    # A pending op must not carry a ghost assignment — one pointing at a dead
    # ghost can neither be spawned (:already_assigned) nor picked up, the
    # deadlock shape from unclean shutdowns. Reset clears the assignment (and
    # reclaims the dead ghost's shell); the spawner then picks it up normally.
    GiTF.Archive.by_index(:ops, :status, "pending")
    |> Enum.filter(fn op -> op.ghost_id != nil and !worker_alive?(op.ghost_id) end)
    |> Enum.each(fn op ->
      Logger.warning("Clearing dead-ghost assignment on pending op #{op.id}")
      GiTF.Ops.reset(op.id)
    end)
  end

  defp worker_alive?(nil), do: false

  defp worker_alive?(ghost_id) do
    case GiTF.Ghost.Worker.lookup(ghost_id) do
      {:ok, pid} -> Process.alive?(pid)
      :error -> false
    end
  end

  defp retry_exists?(op_id) do
    GiTF.Archive.find_one(:ops, fn j ->
      Map.get(j, :retry_of) == op_id
    end) != nil
  rescue
    _ -> false
  end

  # -- Private: op state timeout detection -----------------------------------

  defp timeout_cfg(key, default), do: Application.get_env(:gitf, :timeouts, [])[key] || default

  defp timeout_stale_jobs do
    now = DateTime.utc_now()
    pending_timeout = timeout_cfg(:pending_timeout_seconds, 600)
    assigned_timeout = timeout_cfg(:assigned_timeout_seconds, 600)

    # Timeout ops stuck in "pending" WITH a ghost assignment — that state is
    # never legitimate (recover_stuck_jobs clears the dead-ghost case; this
    # catches a live-but-wedged ghost). Pending ops WITHOUT an assignment are
    # excluded on purpose: a ready op can queue for a long time waiting on a
    # free ghost slot, and cycling it would churn healthy queues.
    GiTF.Archive.by_index(:ops, :status, "pending")
    |> Enum.each(fn op ->
      age = DateTime.diff(now, op.updated_at || op.inserted_at, :second)

      if age > pending_timeout and op.ghost_id != nil do
        # Only reset if the op is supposed to be active (mission still running)
        quest_active? =
          case GiTF.Archive.get(:missions, op.mission_id) do
            %{status: s} when s in ["active", "implementation"] -> true
            _ -> false
          end

        if quest_active? and GiTF.Ops.ready?(op.id) do
          Logger.warning("Job #{op.id} stuck pending+assigned for #{age}s, resetting")
          GiTF.Ops.reset(op.id, "Timed out in pending state after #{age}s")
        end
      end
    end)

    # Timeout ops stuck in "assigned" (ghost never started working)
    GiTF.Archive.by_index(:ops, :status, "assigned")
    |> Enum.each(fn op ->
      age = DateTime.diff(now, op.updated_at || op.inserted_at, :second)

      if age > assigned_timeout do
        Logger.warning("Job #{op.id} stuck assigned for #{age}s, failing for retry")
        GiTF.Ops.fail(op.id)
      end
    end)
  end

  # -- Public: stall detection -----------------------------------------------

  @doc """
  Detect stalled bees given a snapshot of Major's stall-tracking state.

  Exposed publicly so tests (and Major's own ad-hoc invocations) can drive
  detection without going through the timer. Production usage routes through
  the periodic `:check_stalls` handler, which fetches state from Major.
  """
  @spec detect_stalled_bees(%{
          required(:stall_timeout) => non_neg_integer(),
          required(:last_checkpoint) => map()
        }) :: :ok
  def detect_stalled_bees(%{stall_timeout: stall_timeout, last_checkpoint: last_checkpoint}) do
    do_detect_stalled_bees(stall_timeout, last_checkpoint)
  end

  defp detect_stalled_bees do
    case GiTF.Major.get_stall_state() do
      {:ok, snapshot} -> detect_stalled_bees(snapshot)
      :error -> :ok
    end
  end

  defp do_detect_stalled_bees(stall_timeout, last_checkpoint) do
    now = DateTime.utc_now()
    base_stall_seconds = div(stall_timeout, 1000)

    working_bees = GiTF.Ghosts.list(status: GhostStatus.working())

    Enum.each(working_bees, fn ghost ->
      last_cp = Map.get(last_checkpoint, ghost.id)

      reference_time = if last_cp, do: last_cp.at, else: ghost.inserted_at
      seconds_since = DateTime.diff(now, reference_time, :second)

      stall_seconds = adaptive_stall_timeout(ghost, base_stall_seconds)

      cond do
        seconds_since > stall_seconds * @os_alive_hard_stall_multiplier ->
          # Even a live OS process gets reaped eventually — it may be
          # genuinely spinning.
          handle_hard_stall(ghost, seconds_since)

        seconds_since > stall_seconds * 2 ->
          # Silence ≠ wedged: a CLI ghost emits nothing for the whole
          # duration of one long tool call (npm ci, a cargo build). Run 21's
          # Janitor reaped a live fix ghost 1213s into such a call. If the
          # OS process is still there, defer the reap to the bigger bound
          # above; reap now only when the process is actually gone.
          if ghost_os_alive?(ghost) do
            Logger.info(
              "Ghost #{ghost.id} silent for #{seconds_since}s but its OS process is " <>
                "alive — likely a long tool call; deferring hard-stall until " <>
                "#{stall_seconds * @os_alive_hard_stall_multiplier}s"
            )
          else
            handle_hard_stall(ghost, seconds_since)
          end

        seconds_since > stall_seconds ->
          Logger.warning(
            "Stall detected: ghost #{ghost.id} has not reported in #{seconds_since}s " <>
              "(threshold: #{stall_seconds}s)"
          )

          Phoenix.PubSub.broadcast(
            GiTF.PubSub,
            "section:alerts",
            {:stall_warning, ghost.id, seconds_since}
          )

          GiTF.Observability.Alerts.dispatch_webhook(
            :ghost_stalled,
            "Ghost #{ghost.id} stalled (op #{ghost.op_id || "?"}) — no checkpoint in #{seconds_since}s",
            dedup_key: ghost.id
          )

        true ->
          :ok
      end
    end)
  end

  defp ghost_os_alive?(ghost) do
    case GiTF.Archive.get(:ghosts, ghost.id) do
      %{pid: os_pid} when not is_nil(os_pid) -> GiTF.Runtime.OsProc.alive?(os_pid)
      _ -> false
    end
  rescue
    _ -> false
  end

  defp handle_hard_stall(ghost, seconds_since) do
    Logger.warning("Hard-stall: ghost #{ghost.id} unresponsive for #{seconds_since}s, failing op")

    GiTF.Observability.Alerts.dispatch_webhook(
      :ghost_hard_stalled,
      "Ghost #{ghost.id} hard-stalled (op #{ghost.op_id || "?"}) after #{seconds_since}s — " <>
        "killed and failed for retry",
      dedup_key: ghost.id
    )

    # Killing the worker is a cheap side-effect that doesn't touch Major state,
    # so do it here. The rest (Ops.fail, Run notification, retry scheduling,
    # archive update) needs Major's state (retry_pending, max_retries) and must
    # schedule :delayed_retry on Major's mailbox — let Major own that chain.
    #
    # Kill the OS subprocess FIRST (the worker may be wedged and unable to do
    # it in terminate/2), then terminate the worker via its supervisor rather
    # than Process.exit(pid, :kill). A brutal kill is an abnormal exit that a
    # :transient worker RESTARTS — spawning a second subprocess for the same
    # op that races this recovery's fail+retry (a double-spend). Supervisor
    # termination does not trigger a restart.
    kill_ghost_os_process(ghost.id)

    case GiTF.Ghost.Worker.lookup(ghost.id) do
      {:ok, pid} -> GiTF.SectorSupervisor.terminate_child(pid)
      :error -> :ok
    end

    GenServer.cast(GiTF.Major, {:hard_stall_recovery, ghost.id, ghost.op_id, seconds_since})
  end

  # Kill the OS subprocess recorded for a ghost (SIGTERM→SIGKILL), if any.
  defp kill_ghost_os_process(ghost_id) do
    case GiTF.Archive.get(:ghosts, ghost_id) do
      %{pid: os_pid} when not is_nil(os_pid) ->
        GiTF.Runtime.OsProc.terminate(os_pid, [])

      _ ->
        :ok
    end
  rescue
    _ -> :ok
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

  # -- Private: post-review checks -------------------------------------------

  defp check_debriefs do
    # Each review check runs async so validation commands (up to 120s) and
    # auto-revert (which acquires the sector lock) don't block the Janitor.
    GiTF.Debrief.active_reviews()
    |> Enum.each(fn review ->
      Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
        process_debrief_review(review)
      end)
    end)
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

  # -- Private: phase advancement --------------------------------------------

  @phase_statuses ~w(
    research requirements design review planning implementation
    validation awaiting_approval sync simplify scoring
  )

  defp advance_stuck_mission_phases do
    # Periodically call advance_quest for missions in non-terminal phases.
    # Catches cases where a phase ghost completed but the link_msg was lost.
    {finished, live} =
      GiTF.Archive.all(:missions)
      |> Enum.filter(fn q ->
        q[:status] in @phase_statuses or q[:current_phase] in @phase_statuses
      end)
      |> Enum.split_with(&GiTF.Missions.finished?/1)

    # A mission can reach a terminal STATUS while its phase still reads
    # "validation" — a half-finished transition that took a path other than
    # complete_quest/fail_quest. Two consequences, both seen in the wild:
    # the phase filter kept matching it, so this pass re-advanced it every
    # 3 minutes forever; and nobody fired its terminal notification, so the
    # reviewer who asked for the change was never told the run ended.
    Enum.each(finished, &GiTF.Missions.ensure_terminal_notified/1)

    Enum.each(live, fn mission ->
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
  end
end
