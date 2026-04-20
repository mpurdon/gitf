defmodule GiTF.Triage do
  @moduledoc """
  Categorizes ops by complexity and determines what pipeline they need.

  Every op flows through triage before a ghost is spawned. The triage result
  determines whether the op needs scouting (read-only codebase analysis),
  tachikoma verification, and which model tier to use.

  Complexity signals are checked in priority order -- the first match wins.
  """

  alias GiTF.Ops

  @type complexity :: :trivial | :simple | :moderate | :complex

  @type pipeline :: %{
          skip_drone: boolean(),
          skip_scout: boolean(),
          recommended_model: String.t()
        }

  @complex_keywords ~w(refactor redesign migration overhaul architecture)
  @simple_keywords ["fix typo", "update config", "bump version", "rename", "add comment"]

  @complex_regexes Enum.map(@complex_keywords, fn kw ->
                     Regex.compile!("\\b#{Regex.escape(kw)}\\b")
                   end)

  @simple_regexes Enum.map(@simple_keywords, fn kw ->
                    Regex.compile!("\\b#{Regex.escape(kw)}\\b")
                  end)

  # -- Public API --------------------------------------------------------------

  @doc """
  Triages a op map, returning `{complexity, pipeline}`.

  Checks complexity signals in priority order:
  1. Target file count (5+ files => complex)
  2. Dependencies (any => at least moderate)
  3. Architectural keywords in title/description => complex
  4. Simple keywords in title/description => simple
  5. Pre-set `complexity` field from classifier
  6. Default: moderate
  """
  @spec triage(map()) :: {complexity(), pipeline()}
  def triage(op) do
    raw_complexity = determine_complexity(op)
    complexity = maybe_adjust_complexity(raw_complexity, Map.get(op, :sector_id))
    pipeline = pipeline_for(complexity)

    GiTF.Telemetry.emit(
      [:gitf, :triage, :classified],
      %{},
      %{
        op_id: Map.get(op, :id),
        complexity: complexity,
        recommended_model: pipeline.recommended_model,
        title: Map.get(op, :title, "")
      }
    )

    {complexity, pipeline}
  end

  @doc """
  Returns the pipeline config for a given complexity atom.
  """
  @spec pipeline_for(complexity()) :: pipeline()
  def pipeline_for(:trivial) do
    %{skip_drone: true, skip_scout: true, recommended_model: "haiku"}
  end

  def pipeline_for(:simple) do
    %{skip_drone: true, skip_scout: true, recommended_model: "haiku"}
  end

  def pipeline_for(:moderate) do
    %{skip_drone: false, skip_scout: true, recommended_model: "sonnet"}
  end

  def pipeline_for(:complex) do
    %{skip_drone: false, skip_scout: false, recommended_model: "opus"}
  end

  @doc """
  Converts a complexity value from any known representation to the canonical
  atom. Returns `nil` for unrecognized input so callers can fall back to a
  safe default. Input accepted: the canonical atoms themselves (idempotent),
  the M1 triage-phase JSON strings (`"trivial"` / `"simple"` / `"moderate"` /
  `"complex"`), and the op-level classifier strings (`"low"` / `"high"` /
  `"critical"` collapsed to the nearest atom).
  """
  @spec complexity_from_string(term()) :: complexity() | nil
  def complexity_from_string(c) when c in [:trivial, :simple, :moderate, :complex], do: c
  def complexity_from_string("trivial"), do: :trivial
  def complexity_from_string("simple"), do: :simple
  def complexity_from_string("moderate"), do: :moderate
  def complexity_from_string("complex"), do: :complex
  def complexity_from_string("low"), do: :simple
  def complexity_from_string("high"), do: :complex
  def complexity_from_string("critical"), do: :complex
  def complexity_from_string(_), do: nil

  @doc """
  Returns true when the given bug_evidence text contains a concrete signal
  that the issue is already fixed: a commit SHA, a file:line citation, or
  a named test/spec reference. A prose claim is not enough — that's exactly
  what a misfiring triage prompt produces when it's wrong, and we'd rather
  run the full pipeline than short-circuit on a hunch.
  """
  @spec strong_no_work_evidence?(String.t() | nil) :: boolean()
  def strong_no_work_evidence?(nil), do: false
  def strong_no_work_evidence?(""), do: false

  def strong_no_work_evidence?(evidence) when is_binary(evidence) do
    trimmed = String.trim(evidence)

    cond do
      Regex.match?(~r/\b[0-9a-f]{7,40}\b/, trimmed) -> true
      Regex.match?(~r/[\w\/.\-]+\.\w+:\d+/, trimmed) -> true
      Regex.match?(~r/(test\s+"|it\(|describe\(|#\w+\b)/, trimmed) -> true
      true -> false
    end
  end

  def strong_no_work_evidence?(_), do: false

  @doc """
  Returns triage accuracy stats for a sector based on historical feedback.

  Compares triage complexity classification against final quality scores.
  A "miss" is when a mission triaged as simple scored below 70, or when
  a mission triaged as complex scored above 90 (over-estimated).
  """
  @spec accuracy_stats(String.t()) :: %{total: non_neg_integer(), misses: non_neg_integer()}
  def accuracy_stats(sector_id) do
    feedback = GiTF.Archive.filter(:triage_feedback, &(&1.sector_id == sector_id))

    misses =
      Enum.count(feedback, fn f ->
        score = f.quality_score || 0

        # Vocabulary aligns with from_classifier/1: trivial/low -> simple, high/critical -> complex
        (f.triage_complexity in ["trivial", "low"] and score < 70) or
          (f.triage_complexity in ["high", "critical"] and score > 90)
      end)

    %{total: length(feedback), misses: misses}
  end

  # -- Private: complexity determination ---------------------------------------

  defp determine_complexity(op) do
    cond do
      many_target_files?(op) -> :complex
      has_dependencies?(op) -> at_least_moderate(op)
      has_architectural_keywords?(op) -> :complex
      has_simple_keywords?(op) -> :simple
      true -> from_classifier(op)
    end
  end

  defp many_target_files?(op) do
    files = Map.get(op, :target_files, [])
    is_list(files) and length(files) >= 5
  end

  defp has_dependencies?(op) do
    op_id = Map.get(op, :id)
    op_id != nil and Ops.dependencies(op_id) != []
  rescue
    _ -> false
  end

  defp at_least_moderate(op) do
    case from_classifier(op) do
      :simple -> :moderate
      other -> other
    end
  end

  defp has_architectural_keywords?(op) do
    text = job_text(op)
    Enum.any?(@complex_regexes, &Regex.match?(&1, text))
  end

  defp has_simple_keywords?(op) do
    text = job_text(op)
    Enum.any?(@simple_regexes, &Regex.match?(&1, text))
  end

  defp from_classifier(op) do
    case Map.get(op, :complexity) do
      c when c in ["trivial", "low"] -> :simple
      "moderate" -> :moderate
      c when c in ["high", "critical"] -> :complex
      _ -> :moderate
    end
  end

  defp job_text(op) do
    title = Map.get(op, :title, "") || ""
    description = Map.get(op, :description, "") || ""
    String.downcase(title <> " " <> description)
  end

  # Consults sector intelligence to adjust complexity based on historical accuracy.
  # Only adjusts at :medium or :high confidence.
  defp maybe_adjust_complexity(complexity, nil), do: complexity

  defp maybe_adjust_complexity(complexity, sector_id) do
    profile = GiTF.Intel.SectorProfile.get_or_compute(sector_id)

    case profile do
      %{confidence: conf, lessons: %{triage_accuracy: %{adjustments: adjustments}}}
      when conf in [:medium, :high] and adjustments != [] ->
        Enum.find_value(adjustments, complexity, fn {from, to} ->
          if from == complexity, do: to
        end)

      _ ->
        complexity
    end
  rescue
    _ -> complexity
  end
end
