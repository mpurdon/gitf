defmodule GiTF.Intel.FailureAnalysis do
  @moduledoc """
  Analyzes op failures to identify patterns and suggest fixes.
  """

  alias GiTF.Archive

  @doc """
  Analyze a failed op and classify the failure.
  Returns failure analysis with type, cause, and suggestions.
  """
  def analyze_failure(op_id, feedback \\ nil) do
    with {:ok, op} <- GiTF.Ops.get(op_id),
         true <- op.status == "failed" do
      failure_type = classify_failure(op, feedback)
      root_cause = identify_root_cause(op, failure_type)
      similar = find_similar_failures(op, failure_type)
      suggestions = generate_suggestions(failure_type, root_cause, similar)

      # Capture the model so we can later answer "what does model X struggle
      # with on op_type Y" via summaries_for_model/2.
      model = GiTF.Runtime.ModelResolver.normalize_key(op[:assigned_model])

      analysis = %{
        id: GiTF.ID.generate(:fa),
        op_id: op_id,
        sector_id: op[:sector_id],
        op_type: op[:op_type],
        model: model,
        failure_type: failure_type,
        root_cause: root_cause,
        similar_count: length(similar),
        suggestions: suggestions,
        feedback: feedback,
        analyzed_at: DateTime.utc_now()
      }

      Archive.insert(:failure_analyses, analysis)
      {:ok, analysis}
    else
      _ -> {:error, :not_failed_job}
    end
  end

  @doc """
  Get failure patterns for a sector.
  """
  def get_failure_patterns(sector_id) do
    analyses = Archive.by_index(:failure_analyses, :sector_id, sector_id)
    total = length(analyses)

    analyses
    |> Enum.group_by(& &1.failure_type)
    |> Enum.map(fn {type, group} ->
      %{
        type: type,
        count: length(group),
        frequency: length(group) / max(total, 1),
        common_causes: extract_common_causes(group)
      }
    end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  @doc """
  Returns recent failure summaries for a (model, op_type) pair, newest first.

  Use this when escalating a retry to a different model — pass the prior
  model's failures into the new prompt as "things to avoid" context.
  """
  @spec summaries_for_model(String.t(), atom() | String.t(), keyword()) :: [map()]
  def summaries_for_model(model, op_type, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)
    normalized = GiTF.Runtime.ModelResolver.normalize_key(model)
    op_type_atom = if is_binary(op_type), do: String.to_existing_atom(op_type), else: op_type

    :failure_analyses
    |> Archive.by_index(:model, normalized)
    |> Enum.filter(&(&1[:op_type] == op_type_atom))
    |> Enum.sort_by(& &1.analyzed_at, {:desc, DateTime})
    |> Enum.take(limit)
    |> Enum.map(&summary_projection/1)
  rescue
    ArgumentError ->
      # op_type atom not loaded — never seen, no failures recorded
      []
  end

  defp summary_projection(fa) do
    %{
      op_id: fa.op_id,
      failure_type: fa.failure_type,
      root_cause: fa.root_cause,
      analyzed_at: fa.analyzed_at
    }
  end

  @doc """
  Learn from failures and store patterns.
  """
  def learn_from_failures(sector_id) do
    patterns = get_failure_patterns(sector_id)

    learning = %{
      id: GiTF.ID.generate(:fl),
      sector_id: sector_id,
      patterns: patterns,
      total_failures: Enum.sum(Enum.map(patterns, & &1.count)),
      learned_at: DateTime.utc_now()
    }

    Archive.insert(:failure_learnings, learning)
    {:ok, learning}
  end

  # Private functions

  # Single source of truth for failure types. Adding a new type means
  # adding ONE entry here — keywords for classification, root cause
  # template, and suggestion list — instead of touching three parallel
  # case blocks (which previously caused a no-match crash when one was
  # missed).
  #
  # `:keywords` is a list of strings; classification matches the first
  # type whose keywords ALL appear in the combined error/feedback text.
  @failure_specs [
    {:empty_completion, %{
       keywords: ["0 file changes"],
       root_cause: "Ghost reported success but produced 0 file changes — model failed to invoke edit tools",
       suggestions: [
         "Use a more capable model that reliably invokes file-edit tools",
         "Verify the prompt explicitly requires file edits before claiming completion",
         "Check that the model received the expected target files"
       ]
     }},
    {:timeout, %{
       keywords: ["timeout"],
       root_cause: "Job exceeded time limit",
       suggestions: ["Break op into smaller tasks", "Increase timeout limit", "Simplify requirements"]
     }},
    {:compilation_error, %{
       keywords: ["compilation"],
       root_cause: &__MODULE__.extract_compilation_error/1,
       suggestions: ["Review syntax errors", "Check dependencies", "Verify imports"]
     }},
    {:test_failure, %{
       keywords: ["test", "failed"],
       root_cause: &__MODULE__.extract_test_failure/1,
       suggestions: ["Review test expectations", "Check test data", "Verify logic"]
     }},
    {:context_overflow, %{
       keywords: ["context"],
       root_cause: "Context usage exceeded limit",
       suggestions: ["Create transfer", "Simplify op scope", "Use more focused context"]
     }},
    {:validation_failure, %{
       keywords: ["validation"],
       root_cause: "Validation command failed",
       suggestions: ["Fix validation errors", "Update validation command", "Review changes"]
     }},
    {:quality_gate_failure, %{
       keywords: ["quality"],
       root_cause: "Code quality below threshold",
       suggestions: ["Improve code quality", "Fix linting issues", "Refactor complex code"]
     }},
    {:security_gate_failure, %{
       keywords: ["security"],
       root_cause: "Security issues detected",
       suggestions: ["Remove secrets", "Update dependencies", "Fix vulnerabilities"]
     }},
    {:merge_conflict, %{
       keywords: ["sync"],
       root_cause: "Git merge conflict",
       suggestions: ["Resolve conflicts manually", "Rebase on latest", "Retry with fresh worktree"]
     }},
    {:unknown, %{
       keywords: [],
       root_cause: "Unknown failure cause",
       suggestions: ["Review error logs", "Check ghost status", "Retry with different model"]
     }}
  ]

  @unknown_spec Keyword.fetch!(@failure_specs, :unknown)
  defp failure_spec(type), do: Keyword.get(@failure_specs, type, @unknown_spec)

  defp classify_failure(op, feedback) do
    combined =
      Enum.join([Map.get(op, :error_message, ""), Map.get(op, :audit_result, ""), feedback || ""], " ")

    Enum.find_value(@failure_specs, :unknown, fn {type, %{keywords: kws}} ->
      if kws != [] and Enum.all?(kws, &String.contains?(combined, &1)), do: type
    end)
  end

  defp identify_root_cause(op, failure_type) do
    case failure_spec(failure_type).root_cause do
      fun when is_function(fun, 1) -> fun.(op)
      str when is_binary(str) -> str
    end
  end

  @doc false
  # Public for capture in @failure_specs above. Not part of the API.
  def extract_compilation_error(op) do
    error_msg = Map.get(op, :error_message, "")

    case Regex.run(~r/error: (.+)/, error_msg) do
      [_, error] -> String.slice(error, 0, 100)
      _ -> "Compilation failed"
    end
  end

  @doc false
  def extract_test_failure(op) do
    output = Map.get(op, :audit_result, "")

    case Regex.run(~r/\d+\) test (.+)/, output) do
      [_, test] -> "Test failed: #{String.slice(test, 0, 50)}"
      _ -> "Tests failed"
    end
  end

  # Uses the :failure_analyses sector_id index — O(failures_in_sector)
  # rather than O(all_ops + per-op classify_failure). Pulls the precomputed
  # failure_type stored at analyze_failure time instead of re-deriving it
  # from raw error/feedback strings.
  defp find_similar_failures(op, failure_type) do
    :failure_analyses
    |> Archive.by_index(:sector_id, op.sector_id)
    |> Enum.filter(fn fa ->
      fa.failure_type == failure_type and fa.op_id != op.id
    end)
    |> Enum.take(5)
  end

  defp generate_suggestions(failure_type, _root_cause, similar) do
    base_suggestions = failure_spec(failure_type).suggestions

    pattern_suggestions =
      if length(similar) > 2 do
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

end
