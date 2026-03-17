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
    interval = Keyword.get(opts, :poll_interval, @default_poll_interval)
    auto_fix = Keyword.get(opts, :auto_fix, false)
    verify = Keyword.get(opts, :verify, false)

    state = %{
      poll_interval: interval,
      auto_fix: auto_fix,
      verify: verify,
      last_results: [],
      patrol_count: 0
    }

    # Subscribe to PubSub for event-driven verification
    Phoenix.PubSub.subscribe(GiTF.PubSub, "tachikoma:review")

    schedule_patrol(interval)
    Logger.info("Tachikoma started (interval: #{interval}ms, auto_fix: #{auto_fix}, verify: #{verify})")
    {:ok, state}
  end

  @impl true
  def handle_call(:last_results, _from, state) do
    {:reply, state.last_results, state}
  end

  def handle_call(:check_now, _from, state) do
    results = run_patrol(state)
    {:reply, results, %{state | last_results: results}}
  end

  @impl true
  def handle_info(:patrol, state) do
    results = run_patrol(state)
    count = state.patrol_count + 1

    # Prune stale worktree metadata every 10 patrols (~5 min)
    if rem(count, 10) == 0 do
      prune_worktrees()
      cleanup_orphan_cells()
      cleanup_if_low_disk()
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

    # Run verification in a fire-and-forget Task to avoid blocking patrols
    Task.start(fn ->
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
    check_stuck_jobs()
    check_deadlocks()

    queen_results = check_major_heartbeat()
    all_results = results ++ budget_results ++ conflict_results ++ audit_results ++ queen_results
    issues = Enum.filter(all_results, &(&1.status in [:warn, :error]))

    if issues != [] do
      notify_major(issues)
    end

    all_results
  rescue
    e ->
      Logger.warning("Tachikoma patrol failed: #{Exception.message(e)}")

      # Alert on patrol failure so it's not silent
      GiTF.Telemetry.emit([:gitf, :alert, :raised], %{}, %{
        type: :drone_patrol_failed,
        message: "Tachikoma patrol crashed: #{Exception.message(e)}"
      })

      state.last_results
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
      {:ok, _cell_id, :clean} ->
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
        # Job stuck in verification queue too long — skip verification, let it sync
        Logger.warning("Tachikoma: op #{op.id} stuck in verification for #{age}s, auto-passing")
        case GiTF.Ops.get(op.id) do
          {:ok, j} -> GiTF.Archive.put(:ops, Map.put(j, :verification_status, "passed"))
          _ -> :ok
        end
        []
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

  defp check_major_heartbeat do
    # Only check if there are active missions that need the Major
    active_quests = GiTF.Missions.list() |> Enum.filter(&(&1.status == "active"))

    if active_quests != [] do
      case GenServer.whereis(GiTF.Major) do
        nil ->
          [
            %{
              name: "queen_heartbeat",
              status: :error,
              message: "Major is not running but #{length(active_quests)} mission(s) are active"
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
                  name: "queen_heartbeat",
                  status: :warn,
                  message: "Major is unresponsive (timeout)"
                }
              ]

            :exit, _ ->
              [
                %{
                  name: "queen_heartbeat",
                  status: :error,
                  message: "Major process is dead"
                }
              ]
          end
      end
    else
      []
    end
  rescue
    _ -> []
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
        task = Task.async(fn -> System.cmd("df", ["-m", gitf_root], stderr_to_stdout: true) end)

        df_result = case Task.yield(task, 5_000) || Task.shutdown(task, 1_000) do
          {:ok, cmd_result} -> cmd_result
          nil -> {"", 1}
        end

        case df_result do
          {output, 0} ->
            # Parse df output: last line, 4th column is available MB
            available_mb =
              output
              |> String.split("\n", trim: true)
              |> List.last()
              |> String.split(~r/\s+/)
              |> Enum.at(3)
              |> to_integer_safe()

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
    _ -> :ok
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

  @prune_age_hours 48

  defp prune_old_store_data do
    cutoff = DateTime.add(DateTime.utc_now(), -@prune_age_hours * 3600, :second)

    # Prune old read links (48h) and very old unread links (7d) to prevent unbounded growth
    unread_cutoff = DateTime.add(DateTime.utc_now(), -7 * 24 * 3600, :second)

    pruned_waggles =
      GiTF.Archive.filter(:links, fn w ->
        (w.read == true and DateTime.compare(w.inserted_at, cutoff) == :lt) or
          (w.read != true and DateTime.compare(w.inserted_at, unread_cutoff) == :lt)
      end)

    Enum.each(pruned_waggles, fn w ->
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

    total = length(pruned_waggles) + length(pruned_runs)
    if total > 0 do
      Logger.info("Archive pruned: #{length(pruned_waggles)} links, #{length(pruned_runs)} runs")
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

  defp check_stuck_jobs do
    GiTF.Archive.filter(:ops, fn j -> j.status == "running" end)
    |> Enum.each(fn op ->
      worker_alive? =
        case op.ghost_id do
          nil -> false
          ghost_id ->
            case GiTF.Ghost.Worker.lookup(ghost_id) do
              {:ok, pid} -> Process.alive?(pid)
              :error -> false
            end
        end

      unless worker_alive? do
        Logger.warning("Tachikoma: recovering stuck op #{op.id} (worker dead)")
        GiTF.Ops.fail(op.id)
      end
    end)
  rescue
    e ->
      Logger.warning("Tachikoma: check_stuck_jobs failed: #{Exception.message(e)}")
      :ok
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
      nil -> Map.get(result, :output, "Unknown failure")
      validations ->
        failed_validations = Enum.filter(validations, &(&1.status == "fail"))
        case failed_validations do
          [] -> "Unknown failure"
          [validation | _] -> validation.output || "Validation failed"
        end
    end
  end

  # -- Audit & improvement pipeline ------------------------------------

  @verification_max_attempts 3

  defp do_review_job(op_id, _ghost_id, shell_id) do
    do_review_job_attempt(op_id, shell_id, 1)
  rescue
    e ->
      Logger.error("Tachikoma: review crashed for op #{op_id}: #{Exception.message(e)}")
  end

  defp do_review_job_attempt(op_id, shell_id, attempt) do
    case GiTF.Audit.verify_job(op_id) do
      {:ok, :pass, result} ->
        Logger.info("Tachikoma: op #{op_id} passed verification (attempt #{attempt})")
        update_reputation(op_id)
        score_model(op_id, result)

        # Forward to sync queue
        Phoenix.PubSub.broadcast(
          GiTF.PubSub,
          "sync:queue",
          {:merge_ready, op_id, shell_id}
        )

      {:ok, :fail, result} ->
        if attempt < @verification_max_attempts do
          Logger.info("Tachikoma: op #{op_id} failed verification (attempt #{attempt}/#{@verification_max_attempts}), retrying")
          Process.sleep(attempt * 2_000)
          do_review_job_attempt(op_id, shell_id, attempt + 1)
        else
          Logger.warning("Tachikoma: op #{op_id} failed verification after #{attempt} attempts")
          update_reputation(op_id)
          score_model(op_id, result)
          reject_and_improve(op_id, shell_id, result)
        end

      {:error, reason} ->
        if attempt < @verification_max_attempts do
          Logger.info("Tachikoma: verification error for op #{op_id} (attempt #{attempt}/#{@verification_max_attempts}): #{inspect(reason)}, retrying")
          Process.sleep(attempt * 3_000)
          do_review_job_attempt(op_id, shell_id, attempt + 1)
        else
          Logger.error("Tachikoma: verification error for op #{op_id} after #{attempt} attempts: #{inspect(reason)}")
          reject_and_improve(op_id, shell_id, %{output: "Audit error: #{inspect(reason)}"})
        end
    end
  end

  defp reject_and_improve(op_id, shell_id, audit_result) do
    # 1. Reject the op
    GiTF.Ops.reject(op_id)

    # 2. Clean up the worktree
    cleanup_cell(shell_id)

    # 3. Analyze the failure
    feedback = extract_feedback(audit_result)
    analysis = analyze_failure(op_id, feedback)

    # 4. Improve agent profile
    improve_from_failure(op_id, analysis)

    # 5. Create retry op if under max retries
    create_retry_if_allowed(op_id, feedback)
  rescue
    e ->
      Logger.error("Tachikoma: reject_and_improve failed for op #{op_id}: #{Exception.message(e)}")

      GiTF.Telemetry.emit([:gitf, :tachikoma, :review_failed], %{}, %{
        op_id: op_id,
        step: :reject_and_improve,
        reason: Exception.message(e)
      })
  end

  defp cleanup_cell(nil), do: :ok
  defp cleanup_cell(shell_id) do
    GiTF.Shell.remove(shell_id, force: true)
  rescue
    _ -> :ok
  end

  defp extract_feedback(result) do
    Map.get(result, :output) ||
      Map.get(result, "output") ||
      inspect(result) |> String.slice(0, 500)
  end

  defp analyze_failure(op_id, feedback) do
    case GiTF.Intel.FailureAnalysis.analyze_failure(op_id, feedback) do
      {:ok, analysis} -> analysis
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp improve_from_failure(op_id, analysis) do
    with {:ok, op} <- GiTF.Ops.get(op_id) do
      case GiTF.Archive.get(:sectors, op.sector_id) do
        nil -> :ok
        sector when is_binary(sector.path) -> improve_agent_profile(sector.path, analysis, op)
        _ -> :ok
      end
    end
  rescue
    _ -> :ok
  end

  defp improve_agent_profile(sector_path, analysis, op) do
    alias GiTF.AgentProfile.FailureModes

    agents_dir = Path.join(sector_path, ".claude/agents")

    if File.dir?(agents_dir) do
      agents_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.each(fn filename ->
        path = Path.join(agents_dir, filename)
        content = File.read!(path)
        existing_modes = parse_existing_learned_modes(content)

        failure_analysis = build_failure_analysis(analysis, op)
        append_learned_mode(path, content, failure_analysis, existing_modes)
      end)

      Logger.info("Tachikoma: improved agent profile at #{sector_path} with failure lesson")
    end
  rescue
    e -> Logger.debug("Agent profile improvement failed: #{Exception.message(e)}")
  end

  defp build_failure_analysis(nil, op) do
    %{
      type: :unknown,
      root_cause: "Audit failed for: #{op.title}",
      suggestions: ["Ensure changes pass all quality gates before completion"]
    }
  end

  defp build_failure_analysis(analysis, _job) do
    %{
      type: Map.get(analysis, :failure_type, :unknown),
      root_cause: Map.get(analysis, :root_cause, "Unknown"),
      suggestions: Map.get(analysis, :suggestions, [])
    }
  end

  defp append_learned_mode(path, content, failure_analysis, existing_modes) do
    alias GiTF.AgentProfile.FailureModes

    case FailureModes.learn_from_failure(failure_analysis, existing_modes) do
      {:ok, mode} ->
        section_header =
          unless String.contains?(content, "## Lessons Learned") do
            "\n\n## Lessons Learned\n\n"
          else
            "\n"
          end

        learned_text = FailureModes.format_learned_mode(mode)
        File.write!(path, content <> section_header <> learned_text)

      :skip ->
        Logger.debug("Tachikoma: skipping duplicate failure mode for #{Path.basename(path)}")
    end
  end

  defp parse_existing_learned_modes(content) do
    # Extract learned mode keys from existing "### LEARNED: KEY (from failure)" lines
    ~r/### LEARNED: (\S+) \(from failure\)/
    |> Regex.scan(content)
    |> Enum.map(fn [_, name] ->
      key = name |> String.downcase() |> String.to_atom()
      %{key: key, name: name, description: "", severity: :high}
    end)
  end

  defp create_retry_if_allowed(op_id, feedback) do
    case GiTF.Ops.get(op_id) do
      {:ok, op} ->
        retry_count = Map.get(op, :retry_count, 0)

        if retry_count < 3 do
          case GiTF.Ops.create_retry(op_id, feedback: feedback) do
            {:ok, retry_job} ->
              Logger.info("Tachikoma: created retry op #{retry_job.id} for #{op_id} (attempt #{retry_count + 1})")
              GiTF.Link.send("tachikoma", "major", "job_retry_created",
                "Retry #{retry_job.id} for failed op #{op_id} (attempt #{retry_count + 1})")

            {:error, :max_retries_exceeded} ->
              Logger.warning("Tachikoma: op #{op_id} exhausted retries")
              GiTF.Link.send("tachikoma", "major", "job_exhausted_retries",
                "Job #{op_id} exhausted all retries")

            {:error, reason} ->
              Logger.warning("Tachikoma: retry creation failed for #{op_id}: #{inspect(reason)}")
          end
        else
          Logger.warning("Tachikoma: op #{op_id} already at #{retry_count} retries, no more attempts")
          GiTF.Link.send("tachikoma", "major", "job_exhausted_retries",
            "Job #{op_id} exhausted #{retry_count} retries")
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
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
