defmodule Hive.Intelligence.Retry do
  @moduledoc """
  Intelligent retry strategies for failed jobs.
  """

  alias Hive.Intelligence.FailureAnalysis
  alias Hive.Store

  @doc """
  Retry a failed job with an intelligent strategy.
  Returns {:ok, new_job} or {:error, reason}.
  """
  def retry_with_strategy(job_id) do
    with {:ok, job} <- Hive.Jobs.get(job_id),
         {:ok, analysis} <- FailureAnalysis.analyze_failure(job_id) do
      
      strategy = select_strategy(analysis)
      execute_retry(job, strategy, analysis)
    end
  end

  @doc """
  Get recommended retry strategy for a failure type.
  """
  def recommend_strategy(failure_type) do
    case failure_type do
      :timeout -> :simplify_scope
      :compilation_error -> :different_model
      :test_failure -> :more_context
      :context_overflow -> :create_handoff
      :validation_failure -> :different_approach
      :quality_gate_failure -> :improve_quality
      :security_gate_failure -> :fix_security
      :merge_conflict -> :fresh_worktree
      :unknown -> :different_model
    end
  end

  # Private functions

  defp select_strategy(analysis) do
    # Check if this is a recurring failure
    if analysis.similar_count > 2 do
      # Try a different approach for recurring failures
      :different_approach
    else
      recommend_strategy(analysis.failure_type)
    end
  end

  defp execute_retry(job, strategy, analysis) do
    case strategy do
      :different_model ->
        retry_with_different_model(job)
      
      :simplify_scope ->
        retry_with_simplified_scope(job)
      
      :more_context ->
        retry_with_more_context(job)
      
      :create_handoff ->
        create_handoff_and_retry(job)
      
      :different_approach ->
        retry_with_alternative_approach(job)
      
      :fresh_worktree ->
        retry_with_fresh_worktree(job)
      
      _ ->
        # Default: just retry with same settings
        retry_job(job, strategy, analysis)
    end
  end

  defp retry_with_different_model(job) do
    # Switch to a more capable model
    new_model = case Map.get(job, :model) do
      "claude-haiku" -> "claude-sonnet"
      "claude-sonnet" -> "claude-opus"
      _ -> "claude-opus"
    end
    
    retry_job(job, :different_model, %{model: new_model})
  end

  defp retry_with_simplified_scope(job) do
    # Add note to simplify the task
    retry_job(job, :simplify_scope, %{
      note: "Previous attempt timed out. Please simplify the implementation."
    })
  end

  defp retry_with_more_context(job) do
    # Retry with request for more context
    retry_job(job, :more_context, %{
      note: "Previous attempt had test failures. Please review test requirements carefully."
    })
  end

  defp create_handoff_and_retry(job) do
    # This would create a handoff, but for now just note it
    retry_job(job, :create_handoff, %{
      note: "Context overflow detected. Consider breaking into smaller tasks."
    })
  end

  defp retry_with_alternative_approach(job) do
    # Suggest trying a different approach
    retry_job(job, :different_approach, %{
      note: "This is a recurring failure. Please try a different implementation approach."
    })
  end

  defp retry_with_fresh_worktree(job) do
    # Clean up and retry
    retry_job(job, :fresh_worktree, %{
      note: "Merge conflict detected. Starting with fresh worktree."
    })
  end

  defp retry_job(job, strategy, metadata) do
    # Create a new job based on the failed one
    new_job = %{
      id: generate_id("job"),
      quest_id: job.quest_id,
      comb_id: job.comb_id,
      title: job.title,
      description: job.description,
      status: "pending",
      retry_of: job.id,
      retry_strategy: strategy,
      retry_metadata: metadata,
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
    
    Store.insert(:jobs, new_job)
    
    # Update original job to mark it as retried
    updated_original = Map.put(job, :retried_as, new_job.id)
    Store.put(:jobs, updated_original)
    
    {:ok, new_job}
  end

  defp generate_id(prefix) do
    "#{prefix}-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end
end
