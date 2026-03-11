defmodule GiTF.Acceptance do
  @moduledoc """
  Validates work meets acceptance criteria.
  Gates merges on goal achievement and code quality.
  """

  alias GiTF.Archive
  alias GiTF.{Goals, ScopeGuard, Minimalism}

  @doc "Test if op meets acceptance criteria"
  def test_acceptance(op_id) do
    op = Archive.get(:ops, op_id)
    _quest = Archive.get(:missions, op.mission_id)
    
    goal_validation = Goals.validate_job(op_id)
    scope_check = ScopeGuard.check_scope(op_id)
    minimalism_check = Minimalism.analyze_implementation(op_id)
    
    %{
      goal_met: goal_validation.goal_met,
      in_scope: scope_check.in_scope,
      is_minimal: minimalism_check.overall_rating in [:excellent, :good],
      quality_passed: check_quality(op),
      ready_to_merge: ready_to_merge?(goal_validation, scope_check, minimalism_check, op),
      blockers: identify_blockers(goal_validation, scope_check, minimalism_check, op)
    }
  end

  @doc "Test if mission meets acceptance criteria"
  def test_quest_acceptance(mission_id) do
    _quest = Archive.get(:missions, mission_id)
    goal_validation = Goals.validate_quest_completion(mission_id)
    scope_check = ScopeGuard.check_quest_scope(mission_id)
    
    %{
      goal_achieved: goal_validation.goal_achieved == {:achieved, "All ops completed"},
      scope_clean: scope_check.overall_status in [:clean, :acceptable],
      simplicity_score: goal_validation.simplicity_score,
      ready_to_complete: ready_to_complete_quest?(goal_validation, scope_check),
      recommendation: goal_validation.recommendation
    }
  end

  defp check_quality(op) do
    # Check if quality gates passed
    (op[:quality_score] || 0) >= 70 &&
    op.verification_status in ["passed", nil]
  end

  defp ready_to_merge?(goal_validation, scope_check, minimalism_check, op) do
    goal_validation.goal_met &&
    scope_check.in_scope &&
    minimalism_check.overall_rating in [:excellent, :good, :acceptable] &&
    check_quality(op)
  end

  defp identify_blockers(goal_validation, scope_check, minimalism_check, op) do
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
    
    blockers = if !check_quality(op) do
      ["Quality checks failed" | blockers]
    else
      blockers
    end
    
    blockers
  end

  defp ready_to_complete_quest?(goal_validation, scope_check) do
    goal_validation.goal_achieved == {:achieved, "All ops completed"} &&
    scope_check.overall_status in [:clean, :acceptable] &&
    goal_validation.simplicity_score >= 60
  end
end
