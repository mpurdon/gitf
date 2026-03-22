defmodule GiTF.Tachikoma.Scoring do
  @moduledoc """
  Model performance scoring after op verification.

  Transforms verification results into structured scores that track how
  well each model performs across op types. Scores are append-only records
  in the Archive, enabling aggregate analysis of model strengths, weaknesses,
  and op type affinities over time.

  This is a pure context module -- data in, scores out, stored in the Archive.
  """

  alias GiTF.Archive

  @collection :model_scores

  # -- Public API ------------------------------------------------------------

  @doc """
  Scores a model's performance on a op based on verification results.

  Takes the op map and the verification result (from `GiTF.Audit.verify_job/1`).
  Returns a score map with correctness, completeness, code quality, efficiency,
  strengths, weaknesses, and op type fit assessment.
  """
  @spec score(map(), map()) :: map()
  def score(op, audit_result) do
    passed = verification_passed?(audit_result)
    base_scores = base_scores(passed)
    quality_scores = extract_quality_scores(audit_result)
    scores = merge_scores(base_scores, quality_scores)
    {strengths, weaknesses} = analyze_traits(audit_result, passed)
    fit = assess_op_type_fit(passed, scores)

    %{
      model: Map.get(op, :assigned_model, "unknown"),
      op_id: op.id,
      op_type: Map.get(op, :op_type, "general"),
      passed: passed,
      scores: scores,
      strengths: strengths,
      weaknesses: weaknesses,
      op_type_fit: fit
    }
  end

  @doc """
  Records a score map in the Archive. Returns `{:ok, score_record}`.
  """
  @spec record(map()) :: {:ok, map()}
  def record(score_map) when is_map(score_map) do
    score_map
    |> Map.put(:scored_at, DateTime.utc_now() |> DateTime.truncate(:second))
    |> then(&Archive.insert(@collection, &1))
  end

  @doc """
  Aggregates all scores for a given model.

  Returns a summary with total ops, pass rate, average scores,
  most common strengths/weaknesses, and best/worst op types.
  """
  @spec aggregate(String.t()) :: map()
  def aggregate(model) when is_binary(model) do
    scores = Archive.filter(@collection, &(&1.model == model))
    build_aggregate(model, scores)
  end

  @doc """
  Aggregates scores for a given model filtered to a specific op type.
  """
  @spec aggregate_by_op_type(String.t(), String.t()) :: map()
  def aggregate_by_op_type(model, op_type)
      when is_binary(model) and is_binary(op_type) do
    scores =
      Archive.filter(@collection, fn s ->
        s.model == model and s.op_type == op_type
      end)

    build_aggregate(model, scores)
  end

  # -- Private: scoring logic ------------------------------------------------

  defp verification_passed?(result) do
    status = Map.get(result, :status, "")

    cond do
      status in ["passed", "auto_approved"] -> true
      status == "failed" -> false
      true -> false
    end
  end

  defp base_scores(true = _passed) do
    %{final_output: 70, trajectory: 70, tool_usage: 60, safety_alignment: 70}
  end

  defp base_scores(false = _passed) do
    %{final_output: 30, trajectory: 40, tool_usage: 40, safety_alignment: 50}
  end

  defp extract_quality_scores(result) do
    %{}
    |> maybe_add_quality(:tool_usage, result[:quality_score])
    |> maybe_add_quality(:tool_usage, result[:static_score])
    |> maybe_add_quality(:trajectory, result[:performance_score])
    |> maybe_add_quality(:final_output, result[:cross_audit_score])
  end

  defp maybe_add_quality(acc, _key, nil), do: acc
  defp maybe_add_quality(acc, key, score) when is_number(score), do: Map.put(acc, key, score)
  defp maybe_add_quality(acc, _key, _), do: acc

  defp merge_scores(base, quality) do
    Map.merge(base, quality, fn _key, base_val, quality_val ->
      # Weight quality signals heavily when present
      round(base_val * 0.3 + quality_val * 0.7)
    end)
  end

  defp analyze_traits(result, passed) do
    output = Map.get(result, :output, "") || ""
    output_lower = String.downcase(output)

    strengths = build_strengths(passed, output_lower, result)
    weaknesses = build_weaknesses(passed, output_lower, result)

    {strengths, weaknesses}
  end

  defp build_strengths(true, _output, result) do
    base = ["task completion"]

    base
    |> maybe_add_trait(result[:static_score], 80, "clean code")
    |> maybe_add_trait(result[:security_score], 80, "security awareness")
    |> maybe_add_trait(result[:performance_score], 80, "performance")
  end

  defp build_strengths(false, _output, result) do
    []
    |> maybe_add_trait(result[:static_score], 60, "code structure")
    |> maybe_add_trait(result[:security_score], 60, "security awareness")
  end

  defp build_weaknesses(false, output, result) do
    base = ["verification failure"]

    base
    |> then(fn ws ->
      if String.contains?(output, "test"), do: ["test coverage" | ws], else: ws
    end)
    |> then(fn ws ->
      if String.contains?(output, "compile"), do: ["code correctness" | ws], else: ws
    end)
    |> then(fn ws ->
      if String.contains?(output, "timeout"), do: ["efficiency" | ws], else: ws
    end)
    |> maybe_add_weakness(result[:static_score], 40, "code quality")
    |> maybe_add_weakness(result[:security_score], 40, "security")
  end

  defp build_weaknesses(true, _output, result) do
    []
    |> maybe_add_weakness(result[:static_score], 50, "code quality")
    |> maybe_add_weakness(result[:performance_score], 50, "performance")
  end

  defp maybe_add_trait(traits, nil, _threshold, _trait), do: traits

  defp maybe_add_trait(traits, score, threshold, trait) when is_number(score) do
    if score >= threshold, do: [trait | traits], else: traits
  end

  defp maybe_add_trait(traits, _score, _threshold, _trait), do: traits

  defp maybe_add_weakness(weaknesses, nil, _threshold, _weakness), do: weaknesses

  defp maybe_add_weakness(weaknesses, score, threshold, weakness) when is_number(score) do
    if score < threshold, do: [weakness | weaknesses], else: weaknesses
  end

  defp maybe_add_weakness(weaknesses, _score, _threshold, _weakness), do: weaknesses

  defp assess_op_type_fit(passed, scores) do
    avg =
      scores
      |> Map.values()
      |> then(fn vals ->
        if vals == [], do: 0, else: Enum.sum(vals) / length(vals)
      end)

    cond do
      not passed -> :poor
      avg >= 80 -> :excellent
      avg >= 65 -> :good
      avg >= 50 -> :adequate
      true -> :poor
    end
  end

  # -- Private: aggregation --------------------------------------------------

  defp build_aggregate(model, []) do
    %{
      model: model,
      total_jobs: 0,
      pass_rate: 0.0,
      avg_scores: %{final_output: 0.0, trajectory: 0.0, tool_usage: 0.0, safety_alignment: 0.0},
      strengths: [],
      weaknesses: [],
      best_op_types: [],
      worst_op_types: []
    }
  end

  defp build_aggregate(model, scores) do
    total = length(scores)
    passed = Enum.count(scores, & &1.passed)
    pass_rate = passed / total

    avg_scores = average_scores(scores)
    strengths = tally_traits(scores, :strengths)
    weaknesses = tally_traits(scores, :weaknesses)
    {best, worst} = rank_op_types(scores)

    %{
      model: model,
      total_jobs: total,
      pass_rate: Float.round(pass_rate, 3),
      avg_scores: avg_scores,
      strengths: strengths,
      weaknesses: weaknesses,
      best_op_types: best,
      worst_op_types: worst
    }
  end

  defp average_scores(scores) do
    keys = [:final_output, :trajectory, :tool_usage, :safety_alignment]
    total = length(scores)

    Enum.reduce(keys, %{}, fn key, acc ->
      sum =
        scores
        |> Enum.map(fn s -> get_in(s, [:scores, key]) || 0 end)
        |> Enum.sum()

      Map.put(acc, key, Float.round(sum / total, 1))
    end)
  end

  defp tally_traits(scores, field) do
    scores
    |> Enum.flat_map(&(Map.get(&1, field, []) || []))
    |> Enum.frequencies()
    |> Enum.map(fn {trait, count} -> %{trait: trait, frequency: count} end)
    |> Enum.sort_by(& &1.frequency, :desc)
    |> Enum.take(10)
  end

  defp rank_op_types(scores) do
    by_type =
      scores
      |> Enum.group_by(& &1.op_type)
      |> Enum.map(fn {type, type_scores} ->
        total = length(type_scores)
        passed = Enum.count(type_scores, & &1.passed)
        rate = if total > 0, do: passed / total, else: 0.0
        {type, rate}
      end)
      |> Enum.sort_by(&elem(&1, 1), :desc)

    best = by_type |> Enum.take(3) |> Enum.map(&elem(&1, 0))
    worst = by_type |> Enum.reverse() |> Enum.take(3) |> Enum.map(&elem(&1, 0))

    {best, worst}
  end
end
