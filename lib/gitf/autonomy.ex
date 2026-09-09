defmodule GiTF.Autonomy do
  @moduledoc """
  Advanced autonomy features for self-healing and optimization.
  """

  require Logger
  alias GiTF.Archive

  @doc """
  Perform self-healing checks and repairs.
  """
  @spec self_heal() :: [tuple()]
  def self_heal do
    # Batch-load all data once to avoid repeated full-scans of the archive
    ghosts = Archive.all(:ghosts)
    ops = Archive.all(:ops)
    shells = Archive.all(:shells)

    [
      cleanup_orphaned_processes(ghosts, ops),
      reconcile_state(ops, ghosts),
      cleanup_stale_worktrees(shells),
      recover_stuck_jobs(ops)
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Analyze resource utilization and provide optimization recommendations.

  Returns a list of advisory recommendations displayed in the CLI
  (`gitf autonomy`) and dashboard. No automated action is taken on
  these recommendations.
  """
  @spec optimize_resources() :: [{atom(), String.t()}]
  def optimize_resources do
    metrics = collect_metrics()

    recommendations = []

    # Check ghost utilization
    recommendations =
      if metrics.ghost_utilization < 0.5 do
        [{:reduce_ghosts, "Low utilization, consider reducing active ghosts"} | recommendations]
      else
        recommendations
      end

    # Check queue depth
    recommendations =
      if metrics.pending_jobs > 10 do
        [{:increase_ghosts, "High queue depth, consider spawning more ghosts"} | recommendations]
      else
        recommendations
      end

    # Check cost trends
    recommendations =
      if metrics.cost_trend > 1.5 do
        [{:optimize_models, "Cost increasing, consider using cheaper models"} | recommendations]
      else
        recommendations
      end

    recommendations
  end

  @doc """
  Compute the effective ghost cap based on current budget pressure.

  The hard ceiling `max_ghosts` (from config) is scaled down as the hottest
  active mission approaches its budget. This smooths operations: instead of
  running at full steam until the Watchdog pauses a mission, the factory
  slows its burn rate as budget is consumed so remaining ops can complete
  gracefully within the envelope.

  Returns `{target, meta}` where `target` is the new effective cap and
  `meta` includes `:reason` and `:max_util` for logging/telemetry.

  ## Scaling curve

      max_util >= 0.95  → 1              (crawl)
      max_util >= 0.85  → max * 0.5      (aggressive)
      max_util >= 0.70  → max * 0.75     (gentle)
      otherwise         → max_ghosts     (full)

  `target` is always clamped to `[1, max_ghosts]`.
  """
  @spec compute_scaling_decision(pos_integer()) :: {pos_integer(), map()}
  def compute_scaling_decision(max_ghosts) when is_integer(max_ghosts) and max_ghosts >= 1 do
    max_util = max_budget_utilization()

    {ratio, reason} =
      cond do
        max_util >= 0.95 -> {0.0, :budget_critical}
        max_util >= 0.85 -> {0.5, :budget_high}
        max_util >= 0.70 -> {0.75, :budget_moderate}
        true -> {1.0, :headroom}
      end

    target =
      case reason do
        :budget_critical -> 1
        _ -> max(1, min(max_ghosts, ceil(max_ghosts * ratio)))
      end

    {target, %{reason: reason, max_util: max_util}}
  end

  @doc """
  Returns the highest budget utilization (spent / budget) across currently
  active missions, or 0.0 if there are no active missions.

  Single-pass: scans missions and costs once, groups costs by mission_id,
  and avoids re-fetching each mission record via `Budget.budget_for/1`.
  """
  @spec max_budget_utilization() :: float()
  def max_budget_utilization do
    active_statuses = GiTF.Missions.active_statuses()

    active_missions =
      Archive.filter(:missions, fn m -> Map.get(m, :status) in active_statuses end)

    case active_missions do
      [] ->
        0.0

      missions ->
        config_budget = GiTF.Budget.config_budget()
        spent_by_mission = spent_by_mission(missions)

        missions
        |> Enum.map(&mission_utilization(&1, spent_by_mission, config_budget))
        |> Enum.max()
    end
  rescue
    # An unreadable meter reads as full pressure, not none — the number
    # scales ghost concurrency up.
    _ -> 1.0
  end

  # Group cost totals by mission_id in a single scan of :costs.
  # Cost records carry mission_id directly (see `GiTF.Costs.record/2`).
  defp spent_by_mission(missions) do
    mission_ids = missions |> Enum.map(& &1.id) |> MapSet.new()

    Archive.filter(:costs, fn c ->
      MapSet.member?(mission_ids, Map.get(c, :mission_id))
    end)
    |> Enum.reduce(%{}, fn cost, acc ->
      Map.update(acc, cost.mission_id, cost.cost_usd, &(&1 + cost.cost_usd))
    end)
  end

  defp mission_utilization(mission, spent_by_mission, config_budget) do
    budget =
      case Map.get(mission, :budget_override) do
        n when is_number(n) and n > 0 -> n * 1.0
        _ -> config_budget
      end

    spent = Map.get(spent_by_mission, mission.id, 0.0)

    if budget > 0, do: spent / budget, else: 0.0
  end

  @doc """
  Predict likely issues before they occur.

  Combines per-op failure patterns with cross-mission sector trends
  to surface both granular and systemic risks.
  """
  @spec predict_issues(String.t()) :: [{atom(), String.t()}]
  def predict_issues(sector_id) do
    patterns = GiTF.Intel.FailureAnalysis.get_failure_patterns(sector_id)
    insights = GiTF.Intel.get_insights(sector_id)

    predictions = []

    # Predict based on failure rate
    predictions =
      if insights.success_rate < 0.7 do
        [{:high_failure_risk, "Success rate below 70%, expect more failures"} | predictions]
      else
        predictions
      end

    # Predict based on all significant failure patterns
    pattern_predictions =
      for pattern <- patterns,
          pattern.frequency > 0.3 do
        {:recurring_failure,
         "#{pattern.type} failures are common (#{Float.round(pattern.frequency * 100, 1)}%)"}
      end

    # Cross-mission sector trends from recent completed missions
    sector_predictions = cross_mission_predictions(sector_id)

    predictions ++ pattern_predictions ++ sector_predictions
  end

  @doc """
  Create audit trail entry.
  """
  @spec audit(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def audit(action, details) do
    entry = %{
      id: generate_id("audit"),
      action: action,
      details: details,
      timestamp: DateTime.utc_now()
    }

    Archive.insert(:audit_log, entry)
  end

  # Private functions

  defp cleanup_orphaned_processes(ghosts, ops) do
    # Check for ghosts without active ops
    orphaned =
      Enum.filter(ghosts, fn ghost ->
        ghost.status == "active" and
          not has_active_job?(ghost.id, ops)
      end)

    if length(orphaned) > 0 do
      Enum.each(orphaned, fn ghost ->
        Logger.info("Cleaning up orphaned ghost: #{ghost.id}")
        GiTF.Ghosts.stop(ghost.id)
      end)

      {:cleaned_orphaned_ghosts, length(orphaned)}
    else
      nil
    end
  end

  defp reconcile_state(ops, ghosts) do
    # Check for inconsistent state — build a set for O(1) ghost lookup
    active_ghost_ids =
      for ghost <- ghosts, ghost.status == "active", into: MapSet.new(), do: ghost.id

    inconsistent =
      Enum.filter(ops, fn op ->
        op.status == "running" and
          not MapSet.member?(active_ghost_ids, op.ghost_id)
      end)

    if length(inconsistent) > 0 do
      Enum.each(inconsistent, fn op ->
        Logger.warning("Reconciling inconsistent op state: #{op.id}")

        updated =
          Map.put(op, :status, "failed")
          |> Map.put(:error_message, "Ghost disappeared, marked as failed")

        Archive.put(:ops, updated)
      end)

      {:reconciled_jobs, length(inconsistent)}
    else
      nil
    end
  end

  defp cleanup_stale_worktrees(shells) do
    # Check for active worktrees older than 7 days
    cutoff = DateTime.shift(DateTime.utc_now(), day: -7)

    stale =
      Enum.filter(shells, fn shell ->
        shell.status != "removed" and
          DateTime.compare(shell.created_at, cutoff) == :lt
      end)

    if length(stale) > 0 do
      cleaned =
        Enum.count(stale, fn shell ->
          Logger.info("Cleaning up stale worktree: #{shell.id}")

          case GiTF.Shell.remove(shell.id, force: true) do
            {:ok, _} ->
              true

            {:error, reason} ->
              Logger.warning("Failed to clean up stale worktree #{shell.id}: #{inspect(reason)}")

              false
          end
        end)

      {:cleaned_stale_worktrees, cleaned}
    else
      nil
    end
  end

  defp recover_stuck_jobs(ops) do
    # Check for ops stuck in running state for > 1 hour
    cutoff = DateTime.shift(DateTime.utc_now(), hour: -1)

    stuck =
      Enum.filter(ops, fn op ->
        op.status == "running" and
          DateTime.compare(op.updated_at, cutoff) == :lt
      end)

    if length(stuck) > 0 do
      Enum.each(stuck, fn op ->
        Logger.warning("Recovering stuck op: #{op.id}")
        # Attempt intelligent retry
        GiTF.Intel.Retry.retry_with_strategy(op.id)
      end)

      {:recovered_stuck_jobs, length(stuck)}
    else
      nil
    end
  end

  defp has_active_job?(ghost_id, ops) do
    Enum.any?(ops, fn op ->
      op.ghost_id == ghost_id and op.status in ["pending", "running"]
    end)
  end

  defp cross_mission_predictions(sector_id) do
    # Look at the last 20 completed missions for this sector
    recent =
      Archive.filter(:missions, fn m ->
        m.sector_id == sector_id and m.status in ["completed", "failed"]
      end)
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
      |> Enum.take(20)

    if length(recent) < 3 do
      []
    else
      failed = Enum.count(recent, &(&1.status == "failed"))
      total = length(recent)
      failure_rate = failed / total

      predictions = []

      predictions =
        if failure_rate > 0.5 do
          [
            {:sector_degradation,
             "Sector has #{Float.round(failure_rate * 100, 0)}% mission failure rate over last #{total} missions"}
            | predictions
          ]
        else
          predictions
        end

      # Check for budget escalation trend
      triage_feedback = Archive.filter(:triage_feedback, &(&1.sector_id == sector_id))

      low_scores =
        Enum.count(triage_feedback, &((&1.quality_score || 100) < 70))

      predictions =
        if length(triage_feedback) > 5 and low_scores / length(triage_feedback) > 0.3 do
          [{:quality_trend, "Over 30% of missions in this sector score below 70"} | predictions]
        else
          predictions
        end

      predictions
    end
  rescue
    e ->
      Logger.debug(
        "Cross-mission prediction failed for sector #{sector_id}: #{Exception.message(e)}"
      )

      []
  end

  defp collect_metrics do
    ghosts = Archive.all(:ghosts)
    ops = Archive.all(:ops)

    active_ghosts = Enum.count(ghosts, &(&1.status == "active"))
    pending_jobs = Enum.count(ops, &(&1.status == "pending"))

    # Simple utilization calculation
    ghost_utilization =
      if active_ghosts > 0 do
        running_jobs = Enum.count(ops, &(&1.status == "running"))
        running_jobs / active_ghosts
      else
        0
      end

    %{
      ghost_utilization: ghost_utilization,
      pending_jobs: pending_jobs,
      active_ghosts: active_ghosts,
      cost_trend: GiTF.Observability.Metrics.trend(:cost_usd)
    }
  end

  defp generate_id(prefix) do
    "#{prefix}-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end
end
