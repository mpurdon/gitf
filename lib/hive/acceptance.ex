defmodule Hive.Acceptance do
  @moduledoc """
  Validates work meets acceptance criteria.
  Gates merges on goal achievement and code quality.
  """

  alias Hive.Store
  alias Hive.{Goals, ScopeGuard, Minimalism}

  @doc "Test if job meets acceptance criteria"
  def test_acceptance(job_id) do
    job = Store.get(:jobs, job_id)
    quest = Store.get(:quests, job.quest_id)
    
    goal_validation = Goals.validate_job(job_id)
    scope_check = ScopeGuard.check_scope(job_id)
    minimalism_check = Minimalism.analyze_implementation(job_id)
    
    %{
      goal_met: goal_validation.goal_met,
      in_scope: scope_check.in_scope,
      is_minimal: minimalism_check.overall_rating in [:excellent, :good],
      quality_passed: check_quality(job),
      ready_to_merge: ready_to_merge?(goal_validation, scope_check, minimalism_check, job),
      blockers: identify_blockers(goal_validation, scope_check, minimalism_check, job)
    }
  end

  @doc "Test if quest meets acceptance criteria"
  def test_quest_acceptance(quest_id) do
    quest = Store.get(:quests, quest_id)
    goal_validation = Goals.validate_quest_completion(quest_id)
    scope_check = ScopeGuard.check_quest_scope(quest_id)
    
    %{
      goal_achieved: goal_validation.goal_achieved == {:achieved, "All jobs completed"},
      scope_clean: scope_check.overall_status in [:clean, :acceptable],
      simplicity_score: goal_validation.simplicity_score,
      ready_to_complete: ready_to_complete_quest?(goal_validation, scope_check),
      recommendation: goal_validation.recommendation
    }
  end

  defp check_quality(job) do
    # Check if quality gates passed
    (job[:quality_score] || 0) >= 70 &&
    job.verification_status in ["passed", nil]
  end

  defp ready_to_merge?(goal_validation, scope_check, minimalism_check, job) do
    goal_validation.goal_met &&
    scope_check.in_scope &&
    minimalism_check.overall_rating in [:excellent, :good, :acceptable] &&
    check_quality(job)
  end

  defp identify_blockers(goal_validation, scope_check, minimalism_check, job) do
    blockers = []
    
    blockers = if !goal_validation.goal_met do
      ["Goal not achieved" | blockers]
    else
      blockers
    end
    
    blockers = if !scope_check.in_scope do
      ["Scope violations detected" | blockers]
    else
      blockers
    end
    
    blockers = if minimalism_check.overall_rating == :needs_simplification do
      ["Implementation too complex" | blockers]
    else
      blockers
    end
    
    blockers = if !check_quality(job) do
      ["Quality checks failed" | blockers]
    else
      blockers
    end
    
    blockers
  end

  defp ready_to_complete_quest?(goal_validation, scope_check) do
    goal_validation.goal_achieved == {:achieved, "All jobs completed"} &&
    scope_check.overall_status in [:clean, :acceptable] &&
    goal_validation.simplicity_score >= 60
  end
end
