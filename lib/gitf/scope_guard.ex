defmodule GiTF.ScopeGuard do
  @moduledoc """
  Prevents scope creep and over-engineering.
  Ensures ghosts stay focused on the stated goal.
  """

  alias GiTF.Store

  @doc "Check if job stays within scope"
  def check_scope(job_id) do
    job = Store.get(:jobs, job_id)
    quest = Store.get(:quests, job.quest_id)
    
    %{
      in_scope: within_scope?(job, quest),
      warnings: detect_warnings(job, quest),
      recommendation: scope_recommendation(job, quest)
    }
  end

  @doc "Detect scope creep in quest"
  def check_quest_scope(quest_id) do
    quest = Store.get(:quests, quest_id)
    jobs = Store.all(:jobs) |> Enum.filter(&(&1.quest_id == quest_id))
    
    %{
      total_jobs: length(jobs),
      scope_warnings: Enum.flat_map(jobs, &detect_warnings(&1, quest)),
      overall_status: overall_scope_status(jobs, quest)
    }
  end

  defp within_scope?(job, _quest) do
    # Check common scope violations
    files_changed = job[:files_changed] || 0
    
    # Simple heuristic: if too many files, likely scope creep
    files_changed <= 10
  end

  defp detect_warnings(job, _quest) do
    warnings = []
    
    # Too many files
    warnings = if (job[:files_changed] || 0) > 10 do
      [{:too_many_files, "Job modifies #{job[:files_changed]} files"} | warnings]
    else
      warnings
    end
    
    # Job title suggests extra work
    warnings = if job.title && String.contains?(String.downcase(job.title), ["refactor", "improve", "enhance", "optimize"]) do
      [{:potential_gold_plating, "Job title suggests extra work: #{job.title}"} | warnings]
    else
      warnings
    end
    
    warnings
  end

  defp scope_recommendation(job, quest) do
    warnings = detect_warnings(job, quest)
    
    cond do
      Enum.empty?(warnings) -> :approved
      length(warnings) == 1 -> :review_recommended
      true -> :scope_review_required
    end
  end

  defp overall_scope_status(jobs, quest) do
    all_warnings = Enum.flat_map(jobs, &detect_warnings(&1, quest))
    
    cond do
      Enum.empty?(all_warnings) -> :clean
      length(all_warnings) <= 2 -> :acceptable
      true -> :scope_creep_detected
    end
  end
end
