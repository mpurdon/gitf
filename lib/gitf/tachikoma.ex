defmodule GiTF.Tachikoma do
  @moduledoc """
  GenServer that periodically runs health checks (patrols) on the section.

  The Tachikoma is a background watchdog that polls `GiTF.Medic.run_all/1`
  on a fixed interval and notifies the Major when issues are found.
  It follows the same polling pattern as `GiTF.TranscriptWatcher`.

  ## State

      %{
        poll_interval: pos_integer(),
        auto_fix: boolean(),
        last_results: [GiTF.Medic.check_result()]
      }

  ## Lifecycle

  Started on-demand via `gitf tachikoma` or auto-started by the Major.
  Registered in `GiTF.Registry` so there is at most one Tachikoma process.
  """

  use GenServer
  require Logger

  alias GiTF.Runtime.{ProviderCircuit, ProviderManager}

  @default_poll_interval :timer.seconds(30)
  @registry_name GiTF.Registry
  @registry_key :tachikoma

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  # -- Client API --------------------------------------------------------------

  @doc """
  Starts the Tachikoma GenServer.

  ## Options

    * `:poll_interval` - milliseconds between patrols (default: 30s)
    * `:auto_fix` - whether to auto-fix fixable issues (default: false)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = {:via, Registry, {@registry_name, @registry_key}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the results from the most recent patrol."
  @spec last_results() :: [map()]
  def last_results do
    case lookup() do
      {:ok, pid} -> GenServer.call(pid, :last_results)
      :error -> []
    end
  end

  @doc "Triggers an immediate patrol, returning the results."
  @spec check_now() :: [map()]
  def check_now do
    case lookup() do
      {:ok, pid} -> GenServer.call(pid, :check_now, 30_000)
      :error -> []
    end
  end

  @doc "Looks up the Tachikoma process via the Registry."
  @spec lookup() :: {:ok, pid()} | :error
  def lookup do
    case Registry.lookup(@registry_name, @registry_key) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  # -- GenServer callbacks -----------------------------------------------------

  @impl true
  def init(opts) do
    interval =
      Keyword.get(opts, :poll_interval) || GiTF.Config.get(:patrol_interval_ms) ||
        @default_poll_interval

    auto_fix = Keyword.get(opts, :auto_fix, false)
    verify = Keyword.get(opts, :verify, false)

    state = %{
      poll_interval: interval,
      auto_fix: auto_fix,
      verify: verify,
      last_results: [],
      patrol_count: 0,
      # Op IDs that had no live worker on the PREVIOUS patrol — the stuck-op
      # reaper only fails an op on its second consecutive miss.
      stuck_misses: MapSet.new()
    }

    # Subscribe to PubSub for event-driven verification
    Phoenix.PubSub.subscribe(GiTF.PubSub, "tachikoma:review")

    schedule_patrol(interval)

    Logger.info(
      "Tachikoma started (interval: #{interval}ms, auto_fix: #{auto_fix}, verify: #{verify})"
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:last_results, _from, state) do
    {:reply, state.last_results, state}
  end

  def handle_call(:check_now, _from, state) do
    {results, misses} = run_patrol(state)
    {:reply, results, %{state | last_results: results, stuck_misses: misses}}
  end

  @impl true
  def handle_info(:patrol, state) do
    {results, misses} = run_patrol(state)
    state = %{state | stuck_misses: misses}
    count = state.patrol_count + 1

    # Check for zombie missions every 5 patrols (~2.5 min)
    if rem(count, 5) == 0 do
      check_zombie_missions()
      check_stalled_missions()
    end

    # Prune stale worktree metadata every 10 patrols (~5 min)
    if rem(count, 10) == 0 do
      prune_worktrees()
      cleanup_orphan_cells()
      cleanup_if_low_disk()
      check_drift()
      GiTF.Progress.prune_stale()
    end

    # Recompute sector intelligence profiles every 20 patrols (~10 min)
    if rem(count, 20) == 0 do
      recompute_sector_profiles()
      check_model_decay()
    end

    # Prune old completed data every 100 patrols (~50 min)
    if rem(count, 100) == 0 do
      prune_old_store_data()
    end

    schedule_patrol(state.poll_interval)
    {:noreply, %{state | last_results: results, patrol_count: count}}
  end

  # -- PubSub-driven verification (event-driven, no polling delay) ------------

  def handle_info({:review_job, op_id, ghost_id, shell_id}, state) do
    Logger.info("Tachikoma received review request for op #{op_id} (ghost #{ghost_id})")

    # Run verification under TaskSupervisor for proper supervision and crash isolation
    Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
      try do
        do_review_job(op_id, ghost_id, shell_id)
      rescue
        e ->
          Logger.error("Tachikoma: review task crashed for op #{op_id}: #{Exception.message(e)}")

          GiTF.Telemetry.emit([:gitf, :tachikoma, :review_failed], %{}, %{
            op_id: op_id,
            ghost_id: ghost_id,
            step: :review_task,
            reason: Exception.message(e)
          })
      end
    end)

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # -- Private helpers ---------------------------------------------------------

  defp schedule_patrol(interval) do
    Process.send_after(self(), :patrol, interval)
  end

  defp run_patrol(state) do
    results = GiTF.Medic.run_all(fix: state.auto_fix)
    budget_results = check_budgets()
    conflict_results = check_merge_conflicts()
    audit_results = check_verifications()
    circuit_results = probe_provider_circuits()
    misses = check_stuck_jobs(state.stuck_misses)
    check_deadlocks()
    retry_failed_ops()
    check_blocked_ops()

    major_results = check_major_heartbeat()

    all_results =
      results ++
        budget_results ++ conflict_results ++ audit_results ++ circuit_results ++ major_results

    issues = Enum.filter(all_results, &(&1.status in [:warn, :error]))

    if issues != [] do
      notify_major(issues)
    end

    {all_results, misses}
  rescue
    e ->
      Logger.warning("Tachikoma patrol failed: #{Exception.message(e)}")

      # Alert on patrol failure so it's not silent
      GiTF.Telemetry.emit([:gitf, :alert, :raised], %{}, %{
        type: :drone_patrol_failed,
        message: "Tachikoma patrol crashed: #{Exception.message(e)}"
      })

      {state.last_results, state.stuck_misses}
  end

  defp check_budgets do
    GiTF.Missions.list()
    |> Enum.filter(&(&1.status == "active"))
    |> Enum.flat_map(fn mission ->
      remaining = GiTF.Budget.remaining(mission.id)
      budget = GiTF.Budget.budget_for(mission.id)
      pct_used = if budget > 0, do: (1.0 - remaining / budget) * 100, else: 0

      cond do
        remaining < 0 ->
          [
            %{
              name: "budget_check",
              status: :error,
              message: "Quest #{mission.id} exceeded budget ($#{Float.round(-remaining, 2)} over)"
            }
          ]

        pct_used > 80 ->
          [
            %{
              name: "budget_check",
              status: :warn,
              message: "Quest #{mission.id} at #{Float.round(pct_used, 0)}% of budget"
            }
          ]

        true ->
          []
      end
    end)
  rescue
    _ -> []
  end

  defp check_merge_conflicts do
    GiTF.Conflict.check_all_active()
    |> Enum.flat_map(fn
      {:ok, _shell_id, :clean} ->
        []

      {:error, shell_id, :conflicts, files} ->
        [
          %{
            name: "merge_conflicts",
            status: :warn,
            message: "Cell #{shell_id} has conflicts in: #{Enum.join(files, ", ")}"
          }
        ]

      _ ->
        []
    end)
  rescue
    _ -> []
  end

  @verification_max_age_seconds 3600

  defp check_verifications do
    unverified_jobs = GiTF.Audit.jobs_needing_verification()
    now = DateTime.utc_now()

    # Run verification for unverified ops
    Enum.flat_map(unverified_jobs, fn op ->
      age = DateTime.diff(now, op.updated_at || op.inserted_at, :second)

      if age > @verification_max_age_seconds do
        # Job stuck in verification queue too long — retry once with timeout, fail if still stuck
        Logger.warning("Tachikoma: op #{op.id} stuck in verification for #{age}s, retrying")

        task =
          Task.Supervisor.async_nolink(GiTF.TaskSupervisor, fn ->
            GiTF.Audit.verify_job(op.id)
          end)

        case Task.yield(task, 60_000) || Task.shutdown(task) do
          {:ok, {:ok, :pass, _result}} ->
            []

          {:ok, {:ok, :fail, result}} ->
            [
              %{
                name: "verification_timeout_failed",
                status: :error,
                message:
                  "Job #{op.id} failed verification after timeout retry: #{format_audit_result(result)}"
              }
            ]

          _timeout_or_error ->
            case GiTF.Ops.get(op.id) do
              {:ok, j} ->
                GiTF.Archive.put(:ops, Map.put(j, :verification_status, "failed"))

              _ ->
                :ok
            end

            [
              %{
                name: "verification_timeout",
                status: :error,
                message: "Job #{op.id} stuck in verification for #{age}s, marked as failed"
              }
            ]
        end
      else
        case GiTF.Audit.verify_job(op.id) do
          {:ok, :pass, _result} ->
            []

          {:ok, :fail, result} ->
            [
              %{
                name: "verification_failed",
                status: :error,
                message: "Job #{op.id} verification failed: #{format_audit_result(result)}"
              }
            ]

          {:error, reason} ->
            [
              %{
                name: "verification_error",
                status: :warn,
                message: "Job #{op.id} verification error: #{inspect(reason)}"
              }
            ]
        end
      end
    end)
  rescue
    _ -> []
  end

  # -- Provider Circuit Probe --------------------------------------------------
  # Tests providers with open circuit breakers and resets them when they recover.
  # Walks providers in priority order (highest first) so the most-preferred
  # provider is healed first.

  defp probe_provider_circuits do
    open_providers = ProviderCircuit.open_providers()

    if open_providers == [] do
      []
    else
      # Order by priority so we heal the most-preferred provider first
      priority = ProviderManager.provider_priority()

      sorted =
        Enum.sort_by(open_providers, fn p ->
          Enum.find_index(priority, &(&1 == p)) || 999
        end)

      # Only probe providers whose interval has elapsed
      {due, skipped} = Enum.split_with(sorted, &ProviderCircuit.probe_due?/1)

      if skipped != [] do
        intervals =
          Enum.map(skipped, fn p ->
            mode = ProviderCircuit.failure_mode(p)
            "#{p}(#{mode}, #{ProviderCircuit.probe_interval(p)}s)"
          end)

        Logger.debug("Tachikoma: skipping probe for #{Enum.join(intervals, ", ")} — not due yet")
      end

      if due != [] do
        Logger.info(
          "Tachikoma: probing #{length(due)} open provider circuit(s): #{Enum.join(due, ", ")}"
        )
      end

      # Run probes under TaskSupervisor to avoid blocking the Tachikoma GenServer.
      # test_connection makes real API calls / shells out to AWS CLI and can hang.
      Enum.each(due, fn provider ->
        ProviderCircuit.record_probe(provider)

        Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
          case ProviderManager.test_connection(provider) do
            {:ok, latency_ms} ->
              ProviderCircuit.reset_provider(provider)

              Logger.info(
                "Tachikoma: provider #{provider} recovered (#{latency_ms}ms), circuit reset to closed"
              )

              Phoenix.PubSub.broadcast(
                GiTF.PubSub,
                "provider:circuit",
                {:circuit_reset, provider, latency_ms}
              )

              GiTF.Telemetry.emit(
                [:gitf, :provider, :circuit_reset],
                %{latency_ms: latency_ms},
                %{
                  provider: provider
                }
              )

            {:error, reason} ->
              Logger.debug("Tachikoma: provider #{provider} still down: #{inspect(reason)}")
          end
        end)
      end)

      # Return current status for open circuits (actual probe results arrive async)
      Enum.map(due, fn provider ->
        %{
          name: "provider_circuit",
          status: :warn,
          message: "Provider #{provider} circuit open, probe dispatched"
        }
      end)
    end
  rescue
    e ->
      Logger.warning("Tachikoma: probe_provider_circuits failed: #{Exception.message(e)}")
      []
  end

  defp check_major_heartbeat do
    # Only check if there are active missions that need the Major
    active_quests = GiTF.Missions.list() |> Enum.filter(&(&1.status == "active"))

    if active_quests != [] do
      case GenServer.whereis(GiTF.Major) do
        nil ->
          # Major is down. Do NOT restart it here — Major is supervised by
          # GiTF.Core.Supervisor (:rest_for_one), which restarts it (and
          # cascades to its dependents) far more safely than a watchdog
          # reaching in to start_link a sibling ever could. Just alert.
          Logger.warning(
            "Major is not running but #{length(active_quests)} mission(s) are active; supervisor should be restarting it"
          )

          alert_major_down("not running")

          [
            %{
              name: "major_heartbeat",
              status: :error,
              message:
                "Major is not running but #{length(active_quests)} mission(s) are active (supervisor restart expected)"
            }
          ]

        pid when is_pid(pid) ->
          try do
            GiTF.Major.status()
            []
          catch
            :exit, {:timeout, _} ->
              [
                %{
                  name: "major_heartbeat",
                  status: :warn,
                  message: "Major is unresponsive (timeout)"
                }
              ]

            :exit, _ ->
              # Stale/dead PID — the supervisor restarts Major; we only alert.
              Logger.warning("Major process is dead; supervisor should be restarting it")
              alert_major_down("process dead")

              [
                %{
                  name: "major_heartbeat",
                  status: :error,
                  message: "Major process is dead (supervisor restart expected)"
                }
              ]
          end
      end
    else
      []
    end
  rescue
    e ->
      # The watchdog must not silently report "healthy" when its OWN health
      # logic throws — that is exactly how a watchdog goes blind.
      Logger.warning("Tachikoma: check_major_heartbeat crashed: #{Exception.message(e)}")

      [%{name: "major_heartbeat", status: :warn, message: "heartbeat check itself failed"}]
  end

  defp alert_major_down(detail) do
    GiTF.Telemetry.emit([:gitf, :alert, :raised], %{}, %{
      type: :major_down,
      message: "Major is down (#{detail}); relying on GiTF.Core.Supervisor to restart it"
    })
  rescue
    _ -> :ok
  end

  # Pre-implementation phases whose stall is invisible to check_zombie_missions
  # (which only inspects implementation-phase missions with impl ops). A
  # provider outage during triage/design/etc. would otherwise strand a mission
  # until the next BEAM restart's startup sweep. NOTE: "pending" is excluded on
  # purpose — a never-started mission is an admission decision for the operator
  # (or Aramaki), not something the watchdog should silently auto-start.
  @early_phases ~w(triage research requirements design review planning)
  @stalled_mission_threshold_seconds 300

  defp check_stalled_missions do
    now = DateTime.utc_now()

    GiTF.Missions.list()
    |> Enum.filter(fn m -> Map.get(m, :current_phase) in @early_phases end)
    |> Enum.filter(fn m -> mission_stale?(m, now) and not mission_has_live_ghost?(m) end)
    |> Enum.each(fn mission ->
      Logger.warning(
        "Tachikoma: re-kicking stalled mission #{mission.id} " <>
          "(phase #{mission.current_phase}, no live ghost) — likely stranded by an outage"
      )

      try do
        GiTF.Major.Orchestrator.advance_quest(mission.id)
      rescue
        e -> Logger.warning("Tachikoma: re-kick of #{mission.id} failed: #{Exception.message(e)}")
      end
    end)
  rescue
    e ->
      Logger.warning("Tachikoma: check_stalled_missions failed: #{Exception.message(e)}")
      :ok
  end

  defp mission_stale?(mission, now) do
    ts = Map.get(mission, :updated_at) || Map.get(mission, :inserted_at)

    case ts do
      %DateTime{} = t -> DateTime.diff(now, t, :second) > @stalled_mission_threshold_seconds
      # No timestamp: treat as stale so it gets re-kicked rather than stranded.
      _ -> true
    end
  end

  defp mission_has_live_ghost?(mission) do
    GiTF.Ops.list(mission_id: mission.id)
    |> Enum.any?(fn op ->
      case op[:ghost_id] && GiTF.Ghost.Worker.lookup(op.ghost_id) do
        {:ok, pid} -> Process.alive?(pid)
        _ -> false
      end
    end)
  rescue
    _ -> false
  end

  defp check_zombie_missions do
    # Find active missions where ALL non-phase ops are terminal (failed/done/rejected)
    # and no ghosts are working — these missions are stuck and need escalation
    GiTF.Missions.list()
    |> Enum.filter(&(&1.status in ["active", "implementation"]))
    |> Enum.each(fn mission ->
      impl_jobs =
        GiTF.Ops.list(mission_id: mission.id)
        |> Enum.reject(& &1[:phase_job])

      if impl_jobs != [] do
        # Pre-build retried_ok once so the per-op resolved? check is O(1).
        retried_ok = GiTF.Ops.retried_ok_set(impl_jobs)

        {all_terminal?, all_resolved?, all_failed_unresolved?} =
          Enum.reduce(impl_jobs, {true, true, true}, fn op, {term?, res?, ufail?} ->
            terminal? = op.status in ["done", "failed", "rejected", "killed"]
            resolved_or_pending? = op_resolved_or_retry_pending?(op, retried_ok)
            failed? = op.status in ["failed", "rejected", "killed"]

            {
              term? and terminal?,
              res? and resolved_or_pending?,
              ufail? and failed? and not resolved_or_pending?
            }
          end)

        any_working =
          impl_jobs
          |> Enum.filter(&(&1[:ghost_id] != nil))
          |> Enum.any?(fn op ->
            case GiTF.Ghost.Worker.lookup(op.ghost_id) do
              {:ok, pid} -> Process.alive?(pid)
              :error -> false
            end
          end)

        cond do
          not all_terminal? or any_working ->
            :ok

          all_resolved? and not all_failed_unresolved? ->
            try do
              GiTF.Major.Orchestrator.advance_quest(mission.id)
            rescue
              e ->
                Logger.warning(
                  "Tachikoma: advance_quest for resolved mission #{mission.id} crashed: #{Exception.message(e)}"
                )

                :ok
            end

          all_failed_unresolved? ->
            Logger.warning(
              "Tachikoma: mission #{mission.id} has all ops failed/rejected " <>
                "(retries exhausted, no in-flight retry, no successful sibling) — marking failed"
            )

            GiTF.Missions.transition_phase(
              mission.id,
              "completed",
              "All ops failed — auto-escalated by Tachikoma"
            )

            GiTF.Missions.update_status!(mission.id)

            GiTF.Telemetry.emit([:gitf, :alert, :raised], %{}, %{
              type: :mission_auto_failed,
              message: "Mission #{mission.id} auto-failed: all #{length(impl_jobs)} ops exhausted"
            })

            GiTF.Link.send(
              "tachikoma",
              "major",
              "mission_exhausted",
              "Mission #{mission.id} auto-failed by Tachikoma: all ops exhausted retries"
            )

          true ->
            try do
              GiTF.Major.Orchestrator.advance_quest(mission.id)
            rescue
              e ->
                Logger.warning(
                  "Tachikoma: advance_quest for stuck mission #{mission.id} crashed: #{Exception.message(e)}"
                )

                :ok
            end
        end
      end
    end)
  rescue
    e ->
      Logger.warning("Tachikoma: check_zombie_missions failed: #{Exception.message(e)}")
      :ok
  end

  defp op_resolved_or_retry_pending?(op, %MapSet{} = retried_ok) do
    GiTF.Ops.resolved?(op, retried_ok) or
      (op.status in ["failed", "rejected", "killed"] and GiTF.Ops.retry_pending?(op))
  end

  defp check_deadlocks do
    GiTF.Missions.list()
    |> Enum.filter(&(&1.status in ["active", "pending", "implementation"]))
    |> Enum.each(fn mission ->
      case GiTF.Resilience.detect_deadlock(mission.id) do
        {:error, {:deadlock, cycles}} ->
          Logger.warning("Deadlock detected in mission #{mission.id}: #{inspect(cycles)}")
          GiTF.Resilience.resolve_deadlock(mission.id, cycles)

        _ ->
          :ok
      end
    end)
  rescue
    e ->
      Logger.warning("Tachikoma: check_deadlocks failed: #{Exception.message(e)}")
      :ok
  end

  defp prune_worktrees do
    GiTF.Archive.all(:sectors)
    |> Enum.each(fn sector ->
      if sector.path && File.dir?(sector.path) do
        GiTF.Git.worktree_prune(sector.path)
      end
    end)
  rescue
    _ -> :ok
  end

  @low_disk_threshold_mb 200

  defp cleanup_if_low_disk do
    case GiTF.gitf_dir() do
      {:ok, gitf_root} ->
        task =
          Task.async(fn ->
            System.cmd("df", ["-Pk", gitf_root],
              stderr_to_stdout: true,
              env: [{"LC_ALL", "C"}, {"LANG", "C"}]
            )
          end)

        df_result =
          case Task.yield(task, 5_000) || Task.shutdown(task, 1_000) do
            {:ok, cmd_result} -> cmd_result
            nil -> {"", 1}
          end

        case df_result do
          {output, 0} ->
            # POSIX df -Pk: Filesystem 1024-blocks Used Available Capacity Mounted-on
            available_mb =
              output
              |> String.split("\n", trim: true)
              |> Enum.drop(1)
              |> Enum.find_value(fn line ->
                case String.split(line, ~r/\s+/, trim: true) do
                  [_fs, _total, _used, avail, _cap, _mount | _] ->
                    case to_integer_safe(avail) do
                      nil -> nil
                      kb -> div(kb, 1024)
                    end

                  _ ->
                    nil
                end
              end)

            if available_mb && available_mb < @low_disk_threshold_mb do
              Logger.warning("Low disk space (#{available_mb}MB), triggering cleanup")

              # 1. Remove completed/stopped shells' worktrees
              GiTF.Archive.filter(:shells, fn c ->
                c.status in ["completed", "stopped", "removed"]
              end)
              |> Enum.each(fn shell ->
                if shell.worktree_path && File.dir?(shell.worktree_path) do
                  File.rm_rf(shell.worktree_path)
                  Logger.info("Disk cleanup: removed worktree #{shell.worktree_path}")
                end
              end)

              # 2. Prune old store backups (keep only most recent)
              store_path = Path.join([gitf_root, ".gitf", "store"])

              if File.dir?(store_path) do
                Path.wildcard(Path.join(store_path, "*.bak*"))
                |> Enum.sort()
                |> Enum.drop(-1)
                |> Enum.each(&File.rm/1)
              end
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("Tachikoma: disk/backup prune failed: #{Exception.message(e)}")
      :ok
  end

  defp to_integer_safe(nil), do: nil

  defp to_integer_safe(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp cleanup_orphan_cells do
    case GiTF.Shell.cleanup_orphans() do
      {:ok, 0} -> :ok
      {:ok, count} -> Logger.info("Tachikoma: cleaned up #{count} orphan shells")
    end
  rescue
    e ->
      Logger.warning("Tachikoma: cleanup_orphan_cells failed: #{Exception.message(e)}")
      :ok
  end

  defp check_drift do
    results = GiTF.Drift.check_all_active()

    # Auto-rebase :behind shells asynchronously so the patrol isn't blocked
    Enum.each(results, fn
      {shell_id, :behind} ->
        Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
          try do
            GiTF.Drift.maybe_auto_rebase(shell_id)
          rescue
            e ->
              Logger.debug("Auto-rebase task failed for #{shell_id}: #{Exception.message(e)}")
          end
        end)

      _ ->
        :ok
    end)

    risky_count = Enum.count(results, fn {_, level} -> level == :risky end)
    conflicted_count = Enum.count(results, fn {_, level} -> level == :conflicted end)

    if risky_count > 0 or conflicted_count > 0 do
      Logger.warning(
        "Drift detected: #{risky_count} risky, #{conflicted_count} conflicted shells"
      )
    end

    :ok
  rescue
    e ->
      Logger.warning("Tachikoma: check_drift failed: #{Exception.message(e)}")
      :ok
  end

  defp recompute_sector_profiles do
    sectors = GiTF.Archive.all(:sectors)

    Enum.each(sectors, fn sector ->
      try do
        GiTF.Intel.SectorProfile.compute(sector.id)
      rescue
        e ->
          Logger.debug("Profile recompute failed for #{sector.id}: #{Exception.message(e)}")
      end
    end)
  rescue
    _ -> :ok
  end

  defp check_model_decay do
    health = GiTF.Intel.DecayDetector.global_health()

    Enum.each(health, fn {model, status} ->
      if status in [:degraded, :failing] do
        Logger.warning("Model decay detected: #{model} is #{status}")

        GiTF.Telemetry.emit([:gitf, :alert, :raised], %{}, %{
          type: :model_decay_detected,
          model: model,
          status: status,
          message: "Model #{model} performance is #{status}"
        })
      end
    end)
  rescue
    _ -> :ok
  end

  defp prune_old_store_data do
    prune_hours = GiTF.Config.get(:archive_prune_age_hours) || 48
    cutoff = DateTime.shift(DateTime.utc_now(), hour: -prune_hours)

    # Prune old read links (48h) and very old unread links (7d) to prevent unbounded growth
    unread_cutoff = DateTime.shift(DateTime.utc_now(), day: -7)

    pruned_links =
      GiTF.Archive.filter(:links, fn w ->
        (w.read == true and DateTime.compare(w.inserted_at, cutoff) == :lt) or
          (w.read != true and DateTime.compare(w.inserted_at, unread_cutoff) == :lt)
      end)

    Enum.each(pruned_links, fn w ->
      GiTF.Archive.delete(:links, w.id)
    end)

    # Prune old completed runs
    pruned_runs =
      GiTF.Archive.filter(:runs, fn r ->
        r.status == "completed" and
          r.completed_at != nil and
          DateTime.compare(r.completed_at, cutoff) == :lt
      end)

    Enum.each(pruned_runs, fn r ->
      GiTF.Archive.delete(:runs, r.id)
    end)

    # Prune old tachikoma scores (keep last 50 per model)
    prune_old_scores()

    # Prune old events (keep 30 days)
    prune_event_store()

    # Prune costs and audit_results for completed missions
    cost_hours = GiTF.Config.get(:cost_retention_hours) || 168
    cost_cutoff = DateTime.shift(DateTime.utc_now(), hour: -cost_hours)
    completed_mission_ids = completed_mission_ids()

    pruned_costs = prune_collection(:costs, cost_cutoff, completed_mission_ids)
    pruned_audits = prune_collection(:audit_results, cost_cutoff, completed_mission_ids)

    # Prune old debriefs (>30 days)
    thirty_day_cutoff = DateTime.shift(DateTime.utc_now(), day: -30)
    pruned_debriefs = prune_by_age(:debriefs, thirty_day_cutoff)

    # Prune phase transitions for old completed missions
    pruned_transitions = prune_by_mission_age(:mission_phase_transitions, thirty_day_cutoff)

    # Prune context snapshots (>7 days)
    seven_day_cutoff = DateTime.shift(DateTime.utc_now(), day: -7)
    pruned_snapshots = prune_by_age(:context_snapshots, seven_day_cutoff)

    # Prune ghost checkpoint backups (>7 days) — retention was previously
    # unwired, so :backups grew without bound.
    pruned_backups = prune_by_age(:backups, seven_day_cutoff)

    # Cap pattern collections at max records
    max_patterns = GiTF.Config.get(:pattern_retention_max) || 200

    pruned_patterns =
      cap_collection(:failure_analyses, max_patterns) +
        cap_collection(:failure_learnings, max_patterns) +
        cap_collection(:success_patterns, max_patterns)

    # Compact artifacts for old completed missions
    compact_days = GiTF.Config.get(:artifact_compact_days) || 7
    compacted = GiTF.Missions.compact_old_artifacts(compact_days)

    total =
      length(pruned_links) + length(pruned_runs) + pruned_costs + pruned_audits +
        pruned_debriefs + pruned_transitions + pruned_snapshots + pruned_backups +
        pruned_patterns + compacted

    if total > 0 do
      Logger.info(
        "Archive pruned: #{length(pruned_links)} links, #{length(pruned_runs)} runs, " <>
          "#{pruned_costs} costs, #{pruned_audits} audits, #{pruned_debriefs} debriefs, " <>
          "#{pruned_transitions} transitions, #{pruned_snapshots} snapshots, " <>
          "#{pruned_backups} backups, #{pruned_patterns} patterns, #{compacted} artifacts compacted"
      )
    end
  rescue
    _ -> :ok
  end

  defp prune_old_scores do
    GiTF.Archive.all(:tachikoma_scores)
    |> Enum.group_by(& &1.model)
    |> Enum.each(fn {_model, scores} ->
      if length(scores) > 50 do
        scores
        |> Enum.sort_by(& &1.inserted_at, {:asc, DateTime})
        |> Enum.drop(-50)
        |> Enum.each(fn s -> GiTF.Archive.delete(:tachikoma_scores, s.id) end)
      end
    end)
  rescue
    _ -> :ok
  end

  defp prune_event_store do
    if Code.ensure_loaded?(GiTF.EventStore) and function_exported?(GiTF.EventStore, :prune, 1) do
      GiTF.EventStore.prune(days: 30)
    end
  rescue
    _ -> :ok
  end

  defp completed_mission_ids do
    GiTF.Archive.filter(:missions, &(&1.status in ["completed", "failed"]))
    |> Enum.map(& &1.id)
    |> MapSet.new()
  rescue
    _ -> MapSet.new()
  end

  # Prune records older than cutoff that belong to completed missions
  defp prune_collection(collection, cutoff, completed_ids) do
    to_delete =
      GiTF.Archive.filter(collection, fn r ->
        mission_id = r[:mission_id]
        inserted = r[:inserted_at] || r[:recorded_at]

        (mission_id == nil or MapSet.member?(completed_ids, mission_id)) and
          inserted != nil and DateTime.compare(inserted, cutoff) == :lt
      end)

    Enum.each(to_delete, &GiTF.Archive.delete(collection, &1.id))
    length(to_delete)
  rescue
    _ -> 0
  end

  defp prune_by_age(collection, cutoff) do
    to_delete =
      GiTF.Archive.filter(collection, fn r ->
        inserted = r[:inserted_at] || r[:recorded_at] || r[:completed_at] || r[:saved_at]
        inserted != nil and DateTime.compare(inserted, cutoff) == :lt
      end)

    Enum.each(to_delete, &GiTF.Archive.delete(collection, &1.id))
    length(to_delete)
  rescue
    _ -> 0
  end

  defp prune_by_mission_age(collection, cutoff) do
    completed_ids = completed_mission_ids()

    to_delete =
      GiTF.Archive.filter(collection, fn r ->
        mission_id = r[:mission_id]
        inserted = r[:inserted_at]

        MapSet.member?(completed_ids, mission_id) and
          inserted != nil and DateTime.compare(inserted, cutoff) == :lt
      end)

    Enum.each(to_delete, &GiTF.Archive.delete(collection, &1.id))
    length(to_delete)
  rescue
    _ -> 0
  end

  defp cap_collection(collection, max) do
    all = GiTF.Archive.all(collection)

    if length(all) > max do
      to_delete =
        all
        |> Enum.sort_by(&(&1[:inserted_at] || &1[:recorded_at]), {:asc, DateTime})
        |> Enum.drop(-max)

      Enum.each(to_delete, &GiTF.Archive.delete(collection, &1.id))
      length(to_delete)
    else
      0
    end
  rescue
    _ -> 0
  end

  # Fresh spawns get this long before the reaper may consider them at all —
  # covers the window where the op record says "running" but the worker's
  # registration / the op→ghost linkage hasn't settled in the Archive yet.
  @stuck_spawn_grace_seconds 60

  # Reaps running ops with no live worker — but only on the SECOND
  # consecutive patrol miss. A one-shot Registry lookup reaped healthy
  # CLI-mode phase ghosts mid-run on the smoke mission (msn-e6cc5b: research
  # ×2, requirements — every death timestamp landed exactly on a patrol
  # tick), turning a momentary lookup miss into a failed op. Takes the
  # previous patrol's miss-set; returns this patrol's, for Tachikoma state.
  defp check_stuck_jobs(prev_misses) do
    now = DateTime.utc_now()

    GiTF.Archive.filter(:ops, fn j -> j.status == "running" end)
    |> Enum.reduce(MapSet.new(), fn op, misses ->
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

      in_grace? =
        case op[:updated_at] || op[:inserted_at] do
          %DateTime{} = t -> DateTime.diff(now, t, :second) < @stuck_spawn_grace_seconds
          _ -> false
        end

      cond do
        worker_alive? or in_grace? ->
          misses

        MapSet.member?(prev_misses, op.id) ->
          Logger.warning(
            "Tachikoma: recovering stuck op #{op.id} (worker dead on 2 consecutive patrols)"
          )

          GiTF.Ops.fail(op.id)
          misses

        true ->
          Logger.info(
            "Tachikoma: op #{op.id} has no live worker (ghost #{inspect(op.ghost_id)}) — " <>
              "first miss, will recover if still dead next patrol"
          )

          MapSet.put(misses, op.id)
      end
    end)
  rescue
    e ->
      Logger.warning("Tachikoma: check_stuck_jobs failed: #{Exception.message(e)}")
      prev_misses
  end

  @retry_cooldown_ms :timer.minutes(2)

  defp retry_failed_ops do
    active_ids = active_mission_ids()
    max_retries = GiTF.Ops.max_retries()

    if active_ids != [] do
      GiTF.Archive.filter(:ops, fn op ->
        op.status == "failed" && op[:mission_id] in active_ids
      end)
      |> Enum.filter(fn op ->
        (op[:retry_count] || 0) < max_retries && !op[:phase_job]
      end)
      |> Enum.filter(fn op ->
        case op[:updated_at] do
          %DateTime{} = t ->
            GiTF.Clock.awake_elapsed(t) * 1000 > @retry_cooldown_ms

          _ ->
            true
        end
      end)
      |> Enum.reject(&retry_already_handled?/1)
      |> Enum.each(fn op ->
        Logger.info(
          "Tachikoma: auto-retrying failed op #{op.id} (retry #{(op[:retry_count] || 0) + 1}/#{max_retries})"
        )

        GiTF.Ops.reset(op.id, nil)
      end)
    end
  rescue
    e ->
      Logger.warning("Tachikoma: retry_failed_ops failed: #{Exception.message(e)}")
      :ok
  end

  defp retry_already_handled?(op) do
    # A separate retry op was already created by Major
    # Op is no longer failed (was reset by Major between filter and process)
    GiTF.Archive.find_one(:ops, fn j -> Map.get(j, :retry_of) == op.id end) != nil ||
      case GiTF.Archive.get(:ops, op.id) do
        %{status: "failed"} -> false
        _ -> true
      end
  end

  defp check_blocked_ops do
    active_ids = active_mission_ids()

    if active_ids != [] do
      GiTF.Archive.filter(:ops, fn op ->
        op.status == "blocked" && op[:mission_id] in active_ids
      end)
      |> Enum.each(fn op ->
        if GiTF.Ops.ready?(op.id) do
          Logger.info("Tachikoma: unblocking op #{op.id} (dependencies resolved)")
          GiTF.Ops.unblock(op.id)
        end
      end)
    end
  rescue
    e ->
      Logger.warning("Tachikoma: check_blocked_ops failed: #{Exception.message(e)}")
      :ok
  end

  defp active_mission_ids do
    # "failed" is terminal too — omitting it meant op auto-retries kept
    # resurrecting work for sealed missions (run 17's closed-mission loop).
    GiTF.Missions.list()
    |> Enum.reject(&(&1[:status] in ["completed", "closed", "killed", "failed"]))
    |> Enum.map(& &1.id)
  rescue
    _ -> []
  end

  defp notify_major(issues) do
    summary =
      issues
      |> Enum.map(fn i -> "#{i.name}: #{i.message}" end)
      |> Enum.join("; ")

    GiTF.Link.send("tachikoma", "major", "health_alert", summary)
  rescue
    e ->
      Logger.warning("Tachikoma: notify_major failed: #{Exception.message(e)}")
      :ok
  end

  defp format_audit_result(result) do
    case Map.get(result, :validations) do
      nil ->
        Map.get(result, :output, "Unknown failure")

      validations ->
        failed_validations = Enum.filter(validations, &(&1.status == "fail"))

        case failed_validations do
          [] -> "Unknown failure"
          [validation | _] -> validation.output || "Validation failed"
        end
    end
  end

  # -- Quality Gate (single-shot, delegates to Togusa for fixes) ----------

  defp do_review_job(op_id, _ghost_id, shell_id) do
    # Run quality gate once — no retries against unchanged code
    case GiTF.Togusa.run_quality_gate(op_id) do
      {:ok, :pass, result} ->
        Logger.info("Tachikoma: op #{op_id} passed quality gate")
        update_reputation(op_id)
        score_model(op_id, result)

        # For pr_branch missions, skip per-op sync — the orchestrator creates
        # a single mission-level PR after validation. Other strategies sync per-op.
        if mission_uses_pr_branch?(op_id) do
          Logger.info("Tachikoma: op #{op_id} passed, deferring sync to mission-level PR")
        else
          Phoenix.PubSub.broadcast(
            GiTF.PubSub,
            "sync:queue",
            {:merge_ready, op_id, shell_id}
          )
        end

      {:ok, :fail, result} ->
        Logger.warning("Tachikoma: op #{op_id} failed quality gate")

        # Load or create fix context for this op
        fix_ctx = load_fix_context(op_id)

        if GiTF.Togusa.FixContext.exhausted?(fix_ctx) do
          Logger.warning("Tachikoma: op #{op_id} fix attempts exhausted, rejecting")
          GiTF.Ops.reject(op_id)
          update_reputation(op_id)
          score_model(op_id, result)
        else
          # Learn from failure (updates agent profile)
          GiTF.Togusa.learn_from_failure(op_id, result)

          # Spawn fix ghost in same worktree with accumulated context
          GiTF.Togusa.request_fix(op_id, shell_id, result, fix_ctx)
        end

      {:error, reason} ->
        Logger.error("Tachikoma: quality gate error for op #{op_id}: #{inspect(reason)}")
        GiTF.Ops.reject(op_id)
    end
  rescue
    e ->
      Logger.error("Tachikoma: review crashed for op #{op_id}: #{Exception.message(e)}")
  end

  defp mission_uses_pr_branch?(op_id) do
    with {:ok, op} <- GiTF.Ops.get(op_id),
         mid when is_binary(mid) <- op[:mission_id],
         mission when not is_nil(mission) <- GiTF.Archive.get(:missions, mid),
         {:ok, sector} <- GiTF.Sector.get(mission.sector_id) do
      Map.get(sector, :sync_strategy) == "pr_branch"
    else
      _ -> false
    end
  end

  defp load_fix_context(op_id) do
    case GiTF.Ops.get(op_id) do
      {:ok, op} ->
        case op[:fix_context] do
          nil -> GiTF.Togusa.FixContext.new(op[:fix_of] || op_id)
          ctx_map -> GiTF.Togusa.FixContext.from_map(ctx_map) || GiTF.Togusa.FixContext.new(op_id)
        end

      _ ->
        GiTF.Togusa.FixContext.new(op_id)
    end
  end


  defp score_model(op_id, audit_result) do
    with {:ok, op} <- GiTF.Ops.get(op_id) do
      score = GiTF.Tachikoma.Scoring.score(op, audit_result)
      GiTF.Tachikoma.Scoring.record(score)
      Logger.debug("Tachikoma: recorded score for model #{score.model} on op #{op_id}")

      try do
        GiTF.GhostID.update_from_score(score.model, score)
      rescue
        e -> Logger.debug("Tachikoma: agent identity update failed: #{Exception.message(e)}")
      end
    end
  rescue
    e ->
      Logger.debug("Tachikoma: scoring failed for op #{op_id}: #{Exception.message(e)}")
      :ok
  end

  defp update_reputation(op_id) do
    GiTF.Trust.update_after_job(op_id)
  rescue
    _ -> :ok
  end
end
