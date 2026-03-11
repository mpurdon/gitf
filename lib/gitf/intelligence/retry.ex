defmodule GiTF.Intelligence.Retry do
  @moduledoc """
  Intelligent retry strategies for failed ops.
  """

  alias GiTF.Intelligence.FailureAnalysis
  alias GiTF.Archive

  @doc """
  Retry a failed op with an intelligent strategy.
  Returns {:ok, new_job} or {:error, reason}.
  """
  def retry_with_strategy(op_id, feedback \\ nil) do
    with {:ok, op} <- GiTF.Ops.get(op_id),
         {:ok, analysis} <- FailureAnalysis.analyze_failure(op_id, feedback) do

      strategy = select_strategy(analysis)
      execute_retry(op, strategy, analysis)
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

  defp execute_retry(op, strategy, analysis) do
    case strategy do
      :different_model ->
        retry_with_different_model(op, analysis)

      :simplify_scope ->
        retry_with_simplified_scope(op, analysis)

      :more_context ->
        retry_with_more_context(op, analysis)

      :create_handoff ->
        create_handoff_and_retry(op, analysis)

      :different_approach ->
        retry_with_alternative_approach(op, analysis)

      :fresh_worktree ->
        retry_with_fresh_worktree(op, analysis)

      _ ->
        # Default: just retry with same settings
        retry_job(op, strategy, analysis)
    end
  end

  defp retry_with_different_model(op, analysis) do
    # Switch to a more capable model
    new_model = case Map.get(op, :model) do
      "claude-haiku" -> "claude-sonnet"
      "claude-sonnet" -> "claude-opus"
      _ -> "claude-opus"
    end

    retry_job(op, :different_model, %{model: new_model, feedback: analysis[:feedback]})
  end

  defp retry_with_simplified_scope(op, analysis) do
    retry_job(op, :simplify_scope, %{
      note: "Previous attempt timed out. Please simplify the implementation.",
      feedback: analysis[:feedback]
    })
  end

  defp retry_with_more_context(op, analysis) do
    retry_job(op, :more_context, %{
      note: "Previous attempt had test failures. Please review test requirements carefully.",
      feedback: analysis[:feedback]
    })
  end

  defp create_handoff_and_retry(op, analysis) do
    retry_job(op, :create_handoff, %{
      note: "Context overflow detected. Consider breaking into smaller tasks.",
      feedback: analysis[:feedback]
    })
  end

  defp retry_with_alternative_approach(op, analysis) do
    retry_job(op, :different_approach, %{
      note: "This is a recurring failure. Please try a different implementation approach.",
      feedback: analysis[:feedback]
    })
  end

  defp retry_with_fresh_worktree(op, analysis) do
    retry_job(op, :fresh_worktree, %{
      note: "Sync conflict detected. Starting with fresh worktree.",
      feedback: analysis[:feedback]
    })
  end

  defp retry_job(op, strategy, metadata) do
    # Create a new op based on the failed one
    new_job = %{
      id: generate_id("op"),
      mission_id: op.mission_id,
      sector_id: op.sector_id,
      title: op.title,
      description: op.description,
      status: "pending",
      retry_of: op.id,
      retry_strategy: strategy,
      retry_metadata: metadata,
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
    
    Archive.insert(:ops, new_job)
    
    # Update original op to mark it as retried
    updated_original = Map.put(op, :retried_as, new_job.id)
    Archive.put(:ops, updated_original)
    
    {:ok, new_job}
  end

  defp generate_id(prefix) do
    "#{prefix}-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end
end
