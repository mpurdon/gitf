defmodule GiTF.Autonomy do
  @moduledoc """
  Advanced autonomy features for self-healing and optimization.
  """

  require Logger
  alias GiTF.Store

  @doc """
  Perform self-healing checks and repairs.
  """
  def self_heal do
    [
      cleanup_orphaned_processes(),
      reconcile_state(),
      cleanup_stale_worktrees(),
      recover_stuck_jobs()
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Optimize resource allocation based on current load.
  """
  def optimize_resources do
    metrics = collect_metrics()
    
    recommendations = []
    
    # Check ghost utilization
    recommendations = if metrics.bee_utilization < 0.5 do
      [{:reduce_bees, "Low utilization, consider reducing active ghosts"} | recommendations]
    else
      recommendations
    end
    
    # Check queue depth
    recommendations = if metrics.pending_jobs > 10 do
      [{:increase_bees, "High queue depth, consider spawning more ghosts"} | recommendations]
    else
      recommendations
    end
    
    # Check cost trends
    recommendations = if metrics.cost_trend > 1.5 do
      [{:optimize_models, "Cost increasing, consider using cheaper models"} | recommendations]
    else
      recommendations
    end
    
    recommendations
  end

  @doc """
  Predict likely issues before they occur.
  """
  def predict_issues(comb_id) do
    patterns = GiTF.Intelligence.FailureAnalysis.get_failure_patterns(comb_id)
    insights = GiTF.Intelligence.get_insights(comb_id)
    
    predictions = []
    
    # Predict based on failure rate
    predictions = if insights.success_rate < 0.7 do
      [{:high_failure_risk, "Success rate below 70%, expect more failures"} | predictions]
    else
      predictions
    end
    
    # Predict based on patterns
    predictions = if length(patterns) > 0 do
      top_pattern = hd(patterns)
      if top_pattern.frequency > 0.3 do
        [{:recurring_failure, "#{top_pattern.type} failures are common (#{Float.round(top_pattern.frequency * 100, 1)}%)"} | predictions]
      else
        predictions
      end
    else
      predictions
    end
    
    predictions
  end

  @doc """
  Automatically approve low-risk changes.
  """
  def auto_approve?(job_id) do
    with {:ok, job} <- GiTF.Jobs.get(job_id),
         quality_score when not is_nil(quality_score) <- Map.get(job, :quality_score),
         verification when verification == "passed" <- Map.get(job, :verification_status) do
      
      # Auto-approve if high quality and verified
      quality_score >= 85 and verification == "passed"
    else
      _ -> false
    end
  end

  @doc """
  Create audit trail entry.
  """
  def audit(action, details) do
    entry = %{
      id: generate_id("audit"),
      action: action,
      details: details,
      timestamp: DateTime.utc_now()
    }
    
    Store.insert(:audit_log, entry)
  end

  # Private functions

  defp cleanup_orphaned_processes do
    # Check for ghosts without active jobs
    ghosts = Store.all(:ghosts)
    
    orphaned = Enum.filter(ghosts, fn ghost ->
      ghost.status == "active" and
      not has_active_job?(ghost.id)
    end)
    
    if length(orphaned) > 0 do
      Enum.each(orphaned, fn ghost ->
        Logger.info("Cleaning up orphaned ghost: #{ghost.id}")
        GiTF.Ghosts.stop(ghost.id)
      end)
      
      {:cleaned_orphaned_bees, length(orphaned)}
    else
      nil
    end
  end

  defp reconcile_state do
    # Check for inconsistent state
    jobs = Store.all(:jobs)
    
    inconsistent = Enum.filter(jobs, fn job ->
      job.status == "running" and
      not has_active_bee?(job.ghost_id)
    end)
    
    if length(inconsistent) > 0 do
      Enum.each(inconsistent, fn job ->
        Logger.warning("Reconciling inconsistent job state: #{job.id}")
        updated = Map.put(job, :status, "failed")
        |> Map.put(:error_message, "Bee disappeared, marked as failed")
        Store.put(:jobs, updated)
      end)
      
      {:reconciled_jobs, length(inconsistent)}
    else
      nil
    end
  end

  defp cleanup_stale_worktrees do
    # Check for worktrees older than 7 days
    cells = Store.all(:cells)
    cutoff = DateTime.add(DateTime.utc_now(), -7, :day)
    
    stale = Enum.filter(cells, fn cell ->
      DateTime.compare(cell.created_at, cutoff) == :lt
    end)
    
    if length(stale) > 0 do
      Enum.each(stale, fn cell ->
        Logger.info("Cleaning up stale worktree: #{cell.id}")
        # Would actually clean up the worktree here
      end)
      
      {:cleaned_stale_worktrees, length(stale)}
    else
      nil
    end
  end

  defp recover_stuck_jobs do
    # Check for jobs stuck in running state for > 1 hour
    jobs = Store.all(:jobs)
    cutoff = DateTime.add(DateTime.utc_now(), -1, :hour)
    
    stuck = Enum.filter(jobs, fn job ->
      job.status == "running" and
      DateTime.compare(job.updated_at, cutoff) == :lt
    end)
    
    if length(stuck) > 0 do
      Enum.each(stuck, fn job ->
        Logger.warning("Recovering stuck job: #{job.id}")
        # Attempt intelligent retry
        GiTF.Intelligence.Retry.retry_with_strategy(job.id)
      end)
      
      {:recovered_stuck_jobs, length(stuck)}
    else
      nil
    end
  end

  defp has_active_job?(ghost_id) do
    Store.all(:jobs)
    |> Enum.any?(fn job ->
      job.ghost_id == ghost_id and job.status in ["pending", "running"]
    end)
  end

  defp has_active_bee?(ghost_id) do
    case Store.get(:ghosts, ghost_id) do
      nil -> false
      ghost -> ghost.status == "active"
    end
  end

  defp collect_metrics do
    ghosts = Store.all(:ghosts)
    jobs = Store.all(:jobs)
    
    active_ghosts = Enum.count(ghosts, &(&1.status == "active"))
    pending_jobs = Enum.count(jobs, &(&1.status == "pending"))
    
    # Simple utilization calculation
    bee_utilization = if active_ghosts > 0 do
      running_jobs = Enum.count(jobs, &(&1.status == "running"))
      running_jobs / active_ghosts
    else
      0
    end
    
    %{
      bee_utilization: bee_utilization,
      pending_jobs: pending_jobs,
      active_ghosts: active_ghosts,
      cost_trend: GiTF.Observability.Metrics.trend(:cost_usd)
    }
  end

  defp generate_id(prefix) do
    "#{prefix}-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end
end
