defmodule GiTF.Barrier do
  @moduledoc """
  Prevents scope creep and over-engineering.
  Ensures ghosts stay focused on the stated goal.
  """

  alias GiTF.Archive

  @doc "Check if op stays within scope"
  def check_scope(op_id) do
    op = Archive.get(:ops, op_id)
    mission = Archive.get(:missions, op.mission_id)
    
    %{
      in_scope: within_scope?(op, mission),
      warnings: detect_warnings(op, mission),
      recommendation: scope_recommendation(op, mission)
    }
  end

  @doc "Detect scope creep in mission"
  def check_quest_scope(mission_id) do
    mission = Archive.get(:missions, mission_id)
    ops = Archive.all(:ops) |> Enum.filter(&(&1.mission_id == mission_id))
    
    %{
      total_jobs: length(ops),
      scope_warnings: Enum.flat_map(ops, &detect_warnings(&1, mission)),
      overall_status: overall_scope_status(ops, mission)
    }
  end

  defp within_scope?(op, _quest) do
    # Check common scope violations
    files_changed = op[:files_changed] || 0
    
    # Simple heuristic: if too many files, likely scope creep
    files_changed <= 10
  end

  defp detect_warnings(op, _quest) do
    warnings = []
    
    # Too many files
    warnings = if (op[:files_changed] || 0) > 10 do
      [{:too_many_files, "Job modifies #{op[:files_changed]} files"} | warnings]
    else
      warnings
    end
    
    # Job title suggests extra work
    warnings = if op.title && String.contains?(String.downcase(op.title), ["refactor", "improve", "enhance", "optimize"]) do
      [{:potential_gold_plating, "Job title suggests extra work: #{op.title}"} | warnings]
    else
      warnings
    end
    
    warnings
  end

  defp scope_recommendation(op, mission) do
    warnings = detect_warnings(op, mission)
    
    cond do
      Enum.empty?(warnings) -> :approved
      length(warnings) == 1 -> :review_recommended
      true -> :scope_review_required
    end
  end

  defp overall_scope_status(ops, mission) do
    all_warnings = Enum.flat_map(ops, &detect_warnings(&1, mission))
    
    cond do
      Enum.empty?(all_warnings) -> :clean
      length(all_warnings) <= 2 -> :acceptable
      true -> :scope_creep_detected
    end
  end
end
