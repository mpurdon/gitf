defmodule Hive.Goals do
  @moduledoc """
  Validates that completed work achieves quest goals.
  Ensures implementations are goal-focused and complete.
  """

  alias Hive.Store

  @doc "Validate quest completion against stated goals"
  def validate_quest_completion(quest_id) do
    quest = Store.get(:quests, quest_id)
    jobs = Store.all(:jobs) |> Enum.filter(&(&1.quest_id == quest_id))
    
    %{
      goal_achieved: analyze_goal_achievement(quest, jobs),
      simplicity_score: measure_simplicity(jobs),
      completeness: check_completeness(quest, jobs),
      recommendation: make_recommendation(quest, jobs)
    }
  end

  @doc "Check if a single job achieves its goal"
  def validate_job(job_id) do
    job = Store.get(:jobs, job_id)
    quest = Store.get(:quests, job.quest_id)
    
    %{
      goal_met: job_achieves_goal?(job, quest),
      scope_violations: check_scope_violations(job, quest),
      simplicity: measure_job_simplicity(job)
    }
  end

  defp analyze_goal_achievement(quest, jobs) do
    completed = Enum.filter(jobs, &(&1.status == "completed"))
    
    if Enum.empty?(completed) do
      {:incomplete, "No completed jobs"}
    else
      # Check if all required functionality is present
      all_done = Enum.all?(jobs, &(&1.status in ["completed", "verified"]))
      
      if all_done do
        {:achieved, "All jobs completed"}
      else
        {:partial, "Some jobs incomplete"}
      end
    end
  end

  defp measure_simplicity(jobs) do
    # Simple heuristic: fewer files changed = simpler
    total_files = jobs |> Enum.map(&(&1[:files_changed] || 1)) |> Enum.sum()
    
    cond do
      total_files <= 5 -> 100
      total_files <= 10 -> 80
      total_files <= 20 -> 60
      true -> 40
    end
  end

  defp check_completeness(quest, jobs) do
    required_jobs = Enum.filter(jobs, &(&1.status != "cancelled"))
    completed_jobs = Enum.filter(required_jobs, &(&1.status in ["completed", "verified"]))
    
    %{
      total: length(required_jobs),
      completed: length(completed_jobs),
      percentage: if(length(required_jobs) > 0, do: length(completed_jobs) / length(required_jobs) * 100, else: 0)
    }
  end

  defp make_recommendation(quest, jobs) do
    {status, _} = analyze_goal_achievement(quest, jobs)
    simplicity = measure_simplicity(jobs)
    
    cond do
      status == :achieved && simplicity >= 80 -> :approve
      status == :achieved && simplicity >= 60 -> :review_simplicity
      status == :achieved -> :simplify_required
      status == :partial -> :continue_work
      true -> :needs_attention
    end
  end

  defp job_achieves_goal?(job, quest) do
    # Basic check: job is completed and verified
    job.status in ["completed", "verified"] && 
    (job.verification_status == "passed" || is_nil(job.verification_status))
  end

  defp check_scope_violations(job, _quest) do
    # Check for common scope violations
    violations = []
    
    # Too many files changed
    violations = if (job[:files_changed] || 0) > 10 do
      ["Too many files changed (#{job[:files_changed]})" | violations]
    else
      violations
    end
    
    violations
  end

  defp measure_job_simplicity(job) do
    files = job[:files_changed] || 1
    
    cond do
      files <= 2 -> 100
      files <= 5 -> 80
      files <= 10 -> 60
      true -> 40
    end
  end
end
