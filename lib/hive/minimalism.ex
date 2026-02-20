defmodule Hive.Minimalism do
  @moduledoc """
  Enforces minimal, focused implementations.
  Detects over-engineering and unnecessary complexity.
  """

  alias Hive.Store

  @doc "Analyze implementation for minimalism"
  def analyze_implementation(job_id) do
    job = Store.get(:jobs, job_id)
    
    %{
      complexity_score: calculate_complexity(job),
      violations: find_violations(job),
      suggestions: suggest_simplifications(job),
      overall_rating: rate_minimalism(job)
    }
  end

  @doc "Check if implementation is minimal"
  def is_minimal?(job_id) do
    job = Store.get(:jobs, job_id)
    violations = find_violations(job)
    
    Enum.empty?(violations)
  end

  defp calculate_complexity(job) do
    # Simple heuristic based on files changed
    files = job[:files_changed] || 1
    
    cond do
      files <= 2 -> 10  # Very simple
      files <= 5 -> 30  # Simple
      files <= 10 -> 60 # Moderate
      true -> 90        # Complex
    end
  end

  defp find_violations(job) do
    violations = []
    
    # Too many files
    violations = if (job[:files_changed] || 0) > 10 do
      [{:too_many_files, "#{job[:files_changed]} files modified"} | violations]
    else
      violations
    end
    
    # Check for common over-engineering patterns in title/description
    text = "#{job.title} #{job[:description] || ""}" |> String.downcase()
    
    violations = if String.contains?(text, ["factory", "builder", "strategy", "adapter", "facade"]) do
      [{:design_pattern_overuse, "Possible unnecessary design patterns"} | violations]
    else
      violations
    end
    
    violations = if String.contains?(text, ["framework", "library", "abstraction layer"]) do
      [{:over_abstraction, "Possible over-abstraction"} | violations]
    else
      violations
    end
    
    violations
  end

  defp suggest_simplifications(job) do
    violations = find_violations(job)
    
    Enum.map(violations, fn
      {:too_many_files, _} -> "Consider splitting into smaller, focused jobs"
      {:design_pattern_overuse, _} -> "Use simpler, direct implementations"
      {:over_abstraction, _} -> "Reduce abstraction layers, favor concrete code"
      _ -> "Simplify implementation"
    end)
  end

  defp rate_minimalism(job) do
    complexity = calculate_complexity(job)
    violations = find_violations(job)
    
    cond do
      complexity <= 30 && Enum.empty?(violations) -> :excellent
      complexity <= 60 && length(violations) <= 1 -> :good
      complexity <= 60 -> :acceptable
      true -> :needs_simplification
    end
  end
end
