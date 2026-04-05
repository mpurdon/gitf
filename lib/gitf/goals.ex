defmodule GiTF.Goals do
  @moduledoc """
  Validates that completed work achieves mission goals.
  Ensures implementations are goal-focused and complete.
  """

  alias GiTF.Archive

  @doc "Validate mission completion against stated goals"
  def validate_quest_completion(mission_id) do
    mission = Archive.get(:missions, mission_id)
    ops = Archive.all(:ops) |> Enum.filter(&(&1.mission_id == mission_id))

    %{
      goal_achieved: analyze_goal_achievement(mission, ops),
      simplicity_score: measure_simplicity(ops),
      completeness: check_completeness(mission, ops),
      recommendation: make_recommendation(mission, ops)
    }
  end

  @doc "Check if a single op achieves its goal"
  def validate_job(op_id) do
    op = Archive.get(:ops, op_id)
    mission = Archive.get(:missions, op.mission_id)

    %{
      goal_met: job_achieves_goal?(op, mission),
      scope_violations: check_scope_violations(op, mission),
      simplicity: measure_job_simplicity(op)
    }
  end

  defp analyze_goal_achievement(_quest, ops) do
    completed = Enum.filter(ops, &(&1.status == "completed"))

    if Enum.empty?(completed) do
      {:incomplete, "No completed ops"}
    else
      # Check if all required functionality is present
      all_done = Enum.all?(ops, &(&1.status in ["completed", "verified"]))

      if all_done do
        {:achieved, "All ops completed"}
      else
        {:partial, "Some ops incomplete"}
      end
    end
  end

  defp measure_simplicity(ops) do
    # Simple heuristic: fewer files changed = simpler
    total_files = ops |> Enum.map(&(&1[:files_changed] || 1)) |> Enum.sum()

    cond do
      total_files <= 5 -> 100
      total_files <= 10 -> 80
      total_files <= 20 -> 60
      true -> 40
    end
  end

  defp check_completeness(_quest, ops) do
    required_jobs = Enum.filter(ops, &(&1.status != "cancelled"))
    completed_jobs = Enum.filter(required_jobs, &(&1.status in ["completed", "verified"]))

    %{
      total: length(required_jobs),
      completed: length(completed_jobs),
      percentage:
        if(length(required_jobs) > 0,
          do: length(completed_jobs) / length(required_jobs) * 100,
          else: 0
        )
    }
  end

  defp make_recommendation(mission, ops) do
    {status, _} = analyze_goal_achievement(mission, ops)
    simplicity = measure_simplicity(ops)

    cond do
      status == :achieved && simplicity >= 80 -> :approve
      status == :achieved && simplicity >= 60 -> :review_simplicity
      status == :achieved -> :simplify_required
      status == :partial -> :continue_work
      true -> :needs_attention
    end
  end

  defp job_achieves_goal?(op, _quest) do
    # Basic check: op is completed and verified
    op.status in ["completed", "verified"] &&
      (op.verification_status == "passed" || is_nil(op.verification_status))
  end

  defp check_scope_violations(op, _quest) do
    # Check for common scope violations
    violations = []

    # Too many files changed
    violations =
      if (op[:files_changed] || 0) > 10 do
        ["Too many files changed (#{op[:files_changed]})" | violations]
      else
        violations
      end

    violations
  end

  defp measure_job_simplicity(op) do
    files = op[:files_changed] || 1

    cond do
      files <= 2 -> 100
      files <= 5 -> 80
      files <= 10 -> 60
      true -> 40
    end
  end
end
