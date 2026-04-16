defmodule GiTF.Intel.Retry do
  @moduledoc """
  Intelligent retry strategies for failed ops.
  """

  alias GiTF.Intel.FailureAnalysis
  alias GiTF.Archive
  alias GiTF.Runtime.ModelResolver

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

  When `sector_id` is provided, consults the sector intelligence profile
  for historically effective strategies before falling back to the static map.
  """
  def recommend_strategy(failure_type, sector_id \\ nil) do
    case sector_id && learned_strategy(failure_type, sector_id) do
      strategy when is_atom(strategy) and not is_nil(strategy) -> strategy
      _ -> static_strategy(failure_type)
    end
  end

  defp static_strategy(failure_type) do
    case failure_type do
      :timeout -> :simplify_scope
      :compilation_error -> :different_model
      :test_failure -> :more_context
      :context_overflow -> :create_handoff
      :validation_failure -> :different_approach
      :quality_gate_failure -> :improve_quality
      :security_gate_failure -> :fix_security
      :merge_conflict -> :fresh_worktree
      # Model didn't make edits — escalate to a more capable model
      :empty_completion -> :different_model
      :unknown -> :different_model
    end
  end

  # Consults sector intelligence for the most effective retry strategy.
  # Returns nil if no data or low confidence.
  defp learned_strategy(_failure_type, sector_id) do
    profile = GiTF.Intel.SectorProfile.get_or_compute(sector_id)

    case profile do
      %{confidence: conf, lessons: %{retry_effectiveness: eff}}
      when conf in [:medium, :high] and map_size(eff) > 0 ->
        # Pick the strategy with the highest success rate (min 3 data points implied by confidence)
        eff
        |> Enum.filter(fn {_strategy, rate} -> is_number(rate) and rate > 0.3 end)
        |> Enum.max_by(fn {_strategy, rate} -> rate end, fn -> nil end)
        |> case do
          {strategy, _rate} -> normalize_strategy(strategy)
          nil -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp normalize_strategy(s) when is_atom(s), do: s
  defp normalize_strategy(s) when is_binary(s), do: String.to_existing_atom(s)
  defp normalize_strategy(_), do: nil

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
    current = Map.get(op, :assigned_model) || Map.get(op, :recommended_model) || "general"
    new_model = ModelResolver.escalate(current) || ModelResolver.resolve("thinking")

    # Pull recent failure summaries for the prior model + this op_type so the
    # new prompt can warn the new model about known failure modes.
    prior_failures =
      FailureAnalysis.summaries_for_model(current, Map.get(op, :op_type, :unknown), limit: 3)

    note =
      if prior_failures == [] do
        "Previous attempt with model #{current} failed (#{analysis.failure_type}). " <>
          "You are a more capable model — make actual code edits using the file tools."
      else
        priors =
          prior_failures
          |> Enum.map(fn f -> "- #{f.failure_type}: #{f.root_cause}" end)
          |> Enum.join("\n")

        "Previous attempts with model #{current} on this kind of task failed:\n" <>
          priors <>
          "\nYou are a more capable model — make actual code edits using the file tools."
      end

    retry_job(op, :different_model, %{
      model: new_model,
      note: note,
      feedback: analysis[:feedback]
    })
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
    # Create a new op based on the failed one, carrying forward all required fields
    new_model = if is_map(metadata), do: metadata[:model], else: nil
    retry_note = if is_map(metadata), do: metadata[:note], else: nil

    # If the failed ghost left a backup checkpoint, include it in the new op's
    # description so the retry ghost can pick up where the crashed attempt
    # left off instead of starting from scratch. Then prepend the strategy
    # note (e.g. "previous model failed because X — avoid Y") so the new
    # ghost sees the guidance up front.
    enriched_description =
      op
      |> enrich_description_with_backup()
      |> prepend_retry_note(retry_note)

    new_job = %{
      id: GiTF.ID.generate(:op),
      mission_id: op.mission_id,
      sector_id: op.sector_id,
      title: op.title,
      description: enriched_description,
      status: "pending",
      ghost_id: nil,
      retry_of: op.id,
      retry_strategy: strategy,
      retry_metadata: metadata,
      assigned_model: new_model || Map.get(op, :assigned_model),
      recommended_model: Map.get(op, :recommended_model),
      risk_level: Map.get(op, :risk_level, :low),
      verification_status: "pending",
      acceptance_criteria: Map.get(op, :acceptance_criteria, []),
      phase_job: Map.get(op, :phase_job, false),
      phase: Map.get(op, :phase),
      skip_verification: Map.get(op, :skip_verification, false),
      depends_on: Map.get(op, :depends_on, []),
      retry_count: (Map.get(op, :retry_count, 0) || 0) + 1,
      files_changed: nil,
      changed_files: nil,
      inserted_at: DateTime.utc_now(),
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    Archive.insert(:ops, new_job)

    # Update original op to mark it as retried
    updated_original = Map.put(op, :retried_as, new_job.id)
    Archive.put(:ops, updated_original)

    {:ok, new_job}
  end

  defp prepend_retry_note(description, nil), do: description
  defp prepend_retry_note(description, ""), do: description

  defp prepend_retry_note(description, note) do
    "## Retry Guidance\n\n" <> note <> "\n\n---\n\n" <> (description || "")
  end

  # Loads the failed op's ghost backup and appends its progress summary to
  # the description. This lets the retry continue from the crash point.
  defp enrich_description_with_backup(op) do
    base_description = op.description || ""

    case op[:ghost_id] do
      nil ->
        base_description

      ghost_id ->
        case GiTF.Backup.load(ghost_id) do
          {:ok, backup} -> base_description <> "\n\n" <> format_backup_context(backup)
          {:error, _} -> base_description
        end
    end
  rescue
    _ -> op.description || ""
  end

  defp format_backup_context(backup) do
    summary = Map.get(backup, :progress_summary) || ""
    pending = Map.get(backup, :pending_work) || ""
    files = Map.get(backup, :files_modified) || []
    iteration = Map.get(backup, :iteration) || 0

    files_section =
      if files == [] do
        ""
      else
        "\n**Files modified so far:**\n" <> Enum.map_join(files, "\n", &"- #{&1}")
      end

    """
    ## Previous Attempt Notes

    The prior attempt on this op crashed mid-work. Use this context to
    resume from where it left off rather than starting from scratch.

    **Iteration reached:** #{iteration}

    **Progress summary:**
    #{summary}

    **Pending work at time of crash:**
    #{pending}
    #{files_section}
    """
    |> String.trim()
  end
end
