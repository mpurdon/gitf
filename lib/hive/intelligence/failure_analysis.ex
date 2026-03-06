defmodule Hive.Intelligence.FailureAnalysis do
  @moduledoc """
  Analyzes job failures to identify patterns and suggest fixes.
  """

  alias Hive.Store

  @doc """
  Analyze a failed job and classify the failure.
  Returns failure analysis with type, cause, and suggestions.
  """
  def analyze_failure(job_id, feedback \\ nil) do
    with {:ok, job} <- Hive.Jobs.get(job_id),
         true <- job.status == "failed" do

      failure_type = classify_failure(job, feedback)
      root_cause = identify_root_cause(job, failure_type)
      similar = find_similar_failures(job, failure_type)
      suggestions = generate_suggestions(failure_type, root_cause, similar)

      analysis = %{
        id: generate_id("fa"),
        job_id: job_id,
        failure_type: failure_type,
        root_cause: root_cause,
        similar_count: length(similar),
        suggestions: suggestions,
        feedback: feedback,
        analyzed_at: DateTime.utc_now()
      }
      
      Store.insert(:failure_analyses, analysis)
      {:ok, analysis}
    else
      _ -> {:error, :not_failed_job}
    end
  end

  @doc """
  Get failure patterns for a comb.
  """
  def get_failure_patterns(comb_id) do
    jobs = Store.filter(:jobs, &(&1.comb_id == comb_id and &1.status == "failed"))
    
    analyses = jobs
    |> Enum.map(&get_analysis(&1.id))
    |> Enum.reject(&is_nil/1)
    
    # Group by failure type
    patterns = analyses
    |> Enum.group_by(& &1.failure_type)
    |> Enum.map(fn {type, group} ->
      %{
        type: type,
        count: length(group),
        frequency: length(group) / max(length(jobs), 1),
        common_causes: extract_common_causes(group)
      }
    end)
    |> Enum.sort_by(& &1.count, :desc)
    
    patterns
  end

  @doc """
  Learn from failures and store patterns.
  """
  def learn_from_failures(comb_id) do
    patterns = get_failure_patterns(comb_id)
    
    learning = %{
      id: generate_id("fl"),
      comb_id: comb_id,
      patterns: patterns,
      total_failures: Enum.sum(Enum.map(patterns, & &1.count)),
      learned_at: DateTime.utc_now()
    }
    
    Store.insert(:failure_learnings, learning)
    {:ok, learning}
  end

  # Private functions

  defp classify_failure(job, feedback) do
    error_msg = Map.get(job, :error_message, "")
    output = Map.get(job, :verification_result, "")
    combined = Enum.join([error_msg, output, feedback || ""], " ")

    cond do
      String.contains?(combined, "timeout") -> :timeout
      String.contains?(combined, "compilation") -> :compilation_error
      String.contains?(combined, "test") && String.contains?(combined, "failed") -> :test_failure
      String.contains?(combined, "context") -> :context_overflow
      String.contains?(combined, "validation") -> :validation_failure
      String.contains?(combined, "quality") -> :quality_gate_failure
      String.contains?(combined, "security") -> :security_gate_failure
      String.contains?(combined, "merge") -> :merge_conflict
      true -> :unknown
    end
  end

  defp identify_root_cause(job, failure_type) do
    case failure_type do
      :timeout -> "Job exceeded time limit"
      :compilation_error -> extract_compilation_error(job)
      :test_failure -> extract_test_failure(job)
      :context_overflow -> "Context usage exceeded limit"
      :validation_failure -> "Validation command failed"
      :quality_gate_failure -> "Code quality below threshold"
      :security_gate_failure -> "Security issues detected"
      :merge_conflict -> "Git merge conflict"
      :unknown -> "Unknown failure cause"
    end
  end

  defp extract_compilation_error(job) do
    error_msg = Map.get(job, :error_message, "")
    
    # Try to extract specific error
    case Regex.run(~r/error: (.+)/, error_msg) do
      [_, error] -> String.slice(error, 0, 100)
      _ -> "Compilation failed"
    end
  end

  defp extract_test_failure(job) do
    output = Map.get(job, :verification_result, "")
    
    # Try to extract test name
    case Regex.run(~r/\d+\) test (.+)/, output) do
      [_, test] -> "Test failed: #{String.slice(test, 0, 50)}"
      _ -> "Tests failed"
    end
  end

  defp find_similar_failures(job, failure_type) do
    Store.filter(:jobs, fn j ->
      j.comb_id == job.comb_id and
      j.status == "failed" and
      j.id != job.id
    end)
    |> Enum.filter(fn j ->
      classify_failure(j, nil) == failure_type
    end)
    |> Enum.take(5)
  end

  defp generate_suggestions(failure_type, _root_cause, similar) do
    base_suggestions = case failure_type do
      :timeout ->
        ["Break job into smaller tasks", "Increase timeout limit", "Simplify requirements"]
      
      :compilation_error ->
        ["Review syntax errors", "Check dependencies", "Verify imports"]
      
      :test_failure ->
        ["Review test expectations", "Check test data", "Verify logic"]
      
      :context_overflow ->
        ["Create handoff", "Simplify job scope", "Use more focused context"]
      
      :validation_failure ->
        ["Fix validation errors", "Update validation command", "Review changes"]
      
      :quality_gate_failure ->
        ["Improve code quality", "Fix linting issues", "Refactor complex code"]
      
      :security_gate_failure ->
        ["Remove secrets", "Update dependencies", "Fix vulnerabilities"]
      
      :merge_conflict ->
        ["Resolve conflicts manually", "Rebase on latest", "Retry with fresh worktree"]
      
      :unknown ->
        ["Review error logs", "Check bee status", "Retry with different model"]
    end
    
    # Add pattern-based suggestions
    pattern_suggestions = if length(similar) > 2 do
      ["This is a recurring issue (#{length(similar)} similar failures)"]
    else
      []
    end
    
    base_suggestions ++ pattern_suggestions
  end

  defp extract_common_causes(analyses) do
    analyses
    |> Enum.map(& &1.root_cause)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_, count} -> count end, :desc)
    |> Enum.take(3)
    |> Enum.map(fn {cause, _} -> cause end)
  end

  defp get_analysis(job_id) do
    Store.all(:failure_analyses)
    |> Enum.find(&(&1.job_id == job_id))
  end

  defp generate_id(prefix) do
    "#{prefix}-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end
end
