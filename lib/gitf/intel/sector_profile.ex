defmodule GiTF.Intel.SectorProfile do
  @moduledoc """
  Aggregates all quality signals for a sector into an actionable intelligence profile.

  One profile per sector, lazily computed and cached in Archive `:sector_profiles`.
  Separates model-agnostic lessons (survive model changes) from model-specific
  data (adapts to fluctuations). Confidence gating ensures low-data sectors
  stick with defaults.

  ## Confidence Levels

      :none    (0 missions)   — all defaults, no prompt context
      :low     (1–4 missions) — minimal prompt note, no parameter changes
      :medium  (5–19 missions) — blend 50/50 with defaults, inject context
      :high    (≥20 missions)  — full parameter overrides, full context
  """

  alias GiTF.Archive

  require Logger

  @stale_minutes 60
  @max_missions 100

  # Default recommendation values (used when confidence is low)
  @default_phase_timeout 900
  @default_max_redesign 2
  @default_max_fix_attempts 2
  @default_strategy_count_moderate 1
  # @default_strategy_count_complex 3 — used only by orchestrator via recommendations
  @default_threshold_adjustment 1.0

  # -- Public API --------------------------------------------------------------

  @doc """
  Returns a cached profile if fresh, recomputes if stale or missing.
  Returns an empty profile for unknown sectors or on error.
  """
  @spec get_or_compute(String.t() | nil) :: map()
  def get_or_compute(nil), do: empty_profile(nil)

  def get_or_compute(sector_id) do
    case Archive.get(:sector_profiles, sector_id) do
      %{computed_at: computed_at} = profile ->
        if stale?(computed_at), do: compute(sector_id), else: profile

      _ ->
        compute(sector_id)
    end
  rescue
    e ->
      Logger.debug(
        "SectorProfile.get_or_compute failed for #{sector_id}: #{Exception.message(e)}"
      )

      empty_profile(sector_id)
  end

  @doc """
  Computes a fresh profile from Archive data and caches it.
  """
  @spec compute(String.t()) :: map()
  def compute(sector_id) do
    # Load all data sources once
    ops = load_sector_ops(sector_id)
    missions = load_sector_missions(sector_id)
    sample_count = length(missions)
    confidence = confidence_level(sample_count)

    # Model-agnostic lessons
    triage_accuracy = compute_triage_accuracy(sector_id)
    common_failures = compute_common_failures(sector_id)
    success_factors = compute_success_factors(sector_id)
    quality_baseline = compute_quality_baseline(ops)
    risky_patterns = extract_risky_patterns(common_failures, triage_accuracy)
    avg_phase_durations = compute_phase_durations(sector_id)
    retry_effectiveness = compute_retry_effectiveness(ops)
    merge_success_rate = compute_merge_success_rate(sector_id)

    lessons = %{
      triage_accuracy: triage_accuracy,
      common_failures: common_failures,
      success_factors: success_factors,
      quality_baseline: quality_baseline,
      risky_patterns: risky_patterns,
      avg_phase_durations: avg_phase_durations,
      retry_effectiveness: retry_effectiveness,
      merge_success_rate: merge_success_rate
    }

    # Model-specific data
    model_data = compute_model_data(ops, sector_id)

    # Derived recommendations
    recommendations = derive_recommendations(lessons, model_data, confidence)

    # Pre-render prompt context
    prompt_context =
      GiTF.Intel.PromptContext.render_context(lessons, model_data, sample_count, confidence)

    profile = %{
      id: sector_id,
      computed_at: DateTime.utc_now(),
      sample_count: sample_count,
      confidence: confidence,
      lessons: lessons,
      model_data: model_data,
      recommendations: recommendations,
      prompt_context: prompt_context
    }

    Archive.put(:sector_profiles, profile)
    profile
  rescue
    e ->
      Logger.debug("SectorProfile.compute failed for #{sector_id}: #{Exception.message(e)}")
      empty_profile(sector_id)
  end

  @doc """
  Marks a profile as stale so the next `get_or_compute` triggers recomputation.
  """
  @spec invalidate(String.t() | nil) :: :ok
  def invalidate(nil), do: :ok

  def invalidate(sector_id) do
    case Archive.get(:sector_profiles, sector_id) do
      %{} = profile ->
        Archive.put(:sector_profiles, %{profile | computed_at: ~U[2000-01-01 00:00:00Z]})

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Returns the confidence level for a given sample count.
  """
  @spec confidence_level(non_neg_integer()) :: :none | :low | :medium | :high
  def confidence_level(0), do: :none
  def confidence_level(n) when n < 5, do: :low
  def confidence_level(n) when n < 20, do: :medium
  def confidence_level(_), do: :high

  @doc """
  Blends a computed value with a default based on confidence.

  At :none/:low, returns the default. At :medium, returns 50/50 blend.
  At :high, returns the computed value.
  """
  @spec blend(number(), number(), :none | :low | :medium | :high) :: number()
  def blend(_computed, default, conf) when conf in [:none, :low], do: default
  def blend(computed, default, :medium), do: round(default * 0.5 + computed * 0.5)
  def blend(computed, _default, :high), do: computed

  # -- Private: Data Loading ---------------------------------------------------

  defp load_sector_ops(sector_id) do
    Archive.filter(:ops, &(&1.sector_id == sector_id))
    |> Enum.sort_by(&(&1[:created_at] || &1[:inserted_at]), {:desc, DateTime})
    |> Enum.take(@max_missions * 5)
  end

  defp load_sector_missions(sector_id) do
    Archive.filter(:missions, fn m ->
      m.sector_id == sector_id and m[:status] in ["completed", "failed"]
    end)
    |> Enum.sort_by(&(&1[:completed_at] || &1[:created_at]), {:desc, DateTime})
    |> Enum.take(@max_missions)
  end

  # -- Private: Triage Accuracy ------------------------------------------------

  defp compute_triage_accuracy(sector_id) do
    feedback = Archive.filter(:triage_feedback, &(&1.sector_id == sector_id))

    if Enum.empty?(feedback) do
      %{miss_rate: 0.0, bias: :balanced, adjustments: []}
    else
      total = length(feedback)

      # Under-estimates: triaged simple/low but scored poorly
      under_estimates =
        Enum.count(feedback, fn f ->
          score = f.quality_score || 100
          f.triage_complexity in ["trivial", "low"] and score < 70
        end)

      # Over-estimates: triaged complex/critical but scored very well
      over_estimates =
        Enum.count(feedback, fn f ->
          score = f.quality_score || 0
          f.triage_complexity in ["high", "critical"] and score > 90
        end)

      misses = under_estimates + over_estimates
      miss_rate = if total > 0, do: Float.round(misses / total, 3), else: 0.0

      bias =
        cond do
          under_estimates > over_estimates * 2 -> :under_estimates
          over_estimates > under_estimates * 2 -> :over_estimates
          true -> :balanced
        end

      # Generate adjustments based on bias
      adjustments =
        cond do
          bias == :under_estimates and miss_rate > 0.2 ->
            [{:simple, :moderate}]

          bias == :over_estimates and miss_rate > 0.2 ->
            [{:complex, :moderate}]

          true ->
            []
        end

      %{miss_rate: miss_rate, bias: bias, adjustments: adjustments}
    end
  end

  # -- Private: Failure Patterns -----------------------------------------------

  defp compute_common_failures(sector_id) do
    GiTF.Intel.FailureAnalysis.get_failure_patterns(sector_id)
    |> Enum.take(5)
    |> Enum.map(fn p ->
      %{
        type: p.type,
        frequency: Float.round(p.frequency, 3),
        top_cause: List.first(p.common_causes) || "unknown"
      }
    end)
  rescue
    _ -> []
  end

  # -- Private: Success Factors ------------------------------------------------

  defp compute_success_factors(sector_id) do
    case GiTF.Intel.SuccessPatterns.get_best_practices(sector_id) do
      %{common_factors: factors} when is_list(factors) ->
        Enum.take(factors, 5)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  # -- Private: Quality Baseline -----------------------------------------------

  defp compute_quality_baseline(ops) do
    scores =
      ops
      |> Enum.filter(&(&1.status == "done" and is_number(&1[:quality_score])))
      |> Enum.map(& &1.quality_score)
      |> Enum.sort()

    if Enum.empty?(scores) do
      %{avg: nil, p25: nil, median: nil, p75: nil}
    else
      len = length(scores)

      %{
        avg: Float.round(Enum.sum(scores) / len, 1),
        p25: Enum.at(scores, div(len, 4)) |> round_or_nil(),
        median: Enum.at(scores, div(len, 2)) |> round_or_nil(),
        p75: Enum.at(scores, div(len * 3, 4)) |> round_or_nil()
      }
    end
  end

  # -- Private: Phase Durations ------------------------------------------------

  defp compute_phase_durations(sector_id) do
    transitions =
      Archive.filter(:mission_phase_transitions, fn t ->
        t[:sector_id] == sector_id or
          (t[:mission_id] && mission_in_sector?(t.mission_id, sector_id))
      end)

    if Enum.empty?(transitions) do
      %{}
    else
      # Group transitions by mission, compute per-phase durations
      transitions
      |> Enum.group_by(& &1.mission_id)
      |> Enum.flat_map(fn {_mid, ts} ->
        sorted = Enum.sort_by(ts, & &1.inserted_at, DateTime)
        compute_durations_from_transitions(sorted)
      end)
      |> Enum.group_by(fn {phase, _dur} -> phase end)
      |> Map.new(fn {phase, durations} ->
        vals = Enum.map(durations, fn {_, d} -> d end)
        avg = if vals != [], do: Float.round(Enum.sum(vals) / length(vals), 0), else: 0
        {phase, avg}
      end)
    end
  rescue
    _ -> %{}
  end

  defp compute_durations_from_transitions(sorted_transitions) do
    sorted_transitions
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [from, to] ->
      phase = Map.get(from, :to_phase) || Map.get(from, :phase, "unknown")
      duration = DateTime.diff(to.inserted_at, from.inserted_at, :second)
      {phase, max(duration, 0)}
    end)
  end

  defp mission_in_sector?(mission_id, sector_id) do
    case Archive.get(:missions, mission_id) do
      %{sector_id: ^sector_id} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  # -- Private: Retry Effectiveness --------------------------------------------

  defp compute_retry_effectiveness(ops) do
    retried_ops = Enum.filter(ops, &(&1[:retry_of] != nil))

    if Enum.empty?(retried_ops) do
      %{}
    else
      retried_ops
      |> Enum.group_by(&(&1[:retry_strategy] || :unknown))
      |> Map.new(fn {strategy, group} ->
        successes = Enum.count(group, &(&1.status == "done"))
        rate = if length(group) > 0, do: Float.round(successes / length(group), 3), else: 0.0
        {strategy, rate}
      end)
    end
  end

  # -- Private: Merge Success (from mission_outcomes) --------------------------

  defp compute_merge_success_rate(sector_id) do
    outcomes = GiTF.Outcomes.terminal_outcomes(sector_id)

    if outcomes == [] do
      %{rate: nil, sample_count: 0, reverted_count: 0, trend: :unknown}
    else
      sorted = Enum.sort_by(outcomes, &(&1.updated_at || &1.inserted_at), {:desc, DateTime})
      total = length(sorted)
      merged = Enum.count(sorted, &(&1.outcome_category == :merged_clean))
      reverted = Enum.count(sorted, &(&1.outcome_category == :merged_reverted))

      recent_n = min(10, max(div(total, 3), 3))
      recent = Enum.take(sorted, recent_n)
      recent_merged = Enum.count(recent, &(&1.outcome_category == :merged_clean))
      recent_rate = if recent_n > 0, do: recent_merged / recent_n, else: nil
      baseline_rate = merged / total

      trend =
        cond do
          total < 8 or recent_n < 3 -> :unknown
          recent_rate && recent_rate - baseline_rate > 0.10 -> :improving
          recent_rate && recent_rate - baseline_rate < -0.15 -> :declining
          true -> :stable
        end

      %{
        rate: Float.round(baseline_rate, 3),
        sample_count: total,
        reverted_count: reverted,
        trend: trend
      }
    end
  rescue
    e ->
      Logger.debug("SectorProfile.compute_merge_success_rate failed: #{Exception.message(e)}")
      %{rate: nil, sample_count: 0, reverted_count: 0, trend: :unknown}
  end

  # -- Private: Model Data -----------------------------------------------------

  defp compute_model_data(ops, sector_id) do
    # Only look at terminal ops with a model assigned
    terminal_ops =
      Enum.filter(ops, fn op ->
        op[:assigned_model] != nil and op.status in ["done", "failed"]
      end)

    if Enum.empty?(terminal_ops) do
      %{}
    else
      terminal_ops
      |> Enum.group_by(&normalize_model(&1.assigned_model))
      |> Enum.reject(fn {model, _} -> is_nil(model) end)
      |> Map.new(fn {model, model_ops} ->
        total = length(model_ops)
        done = Enum.count(model_ops, &(&1.status == "done"))
        success_rate = if total > 0, do: Float.round(done / total, 3), else: 0.0

        quality_scores =
          model_ops
          |> Enum.filter(&(&1.status == "done" and is_number(&1[:quality_score])))
          |> Enum.map(& &1.quality_score)

        avg_quality =
          if quality_scores != [],
            do: Float.round(Enum.sum(quality_scores) / length(quality_scores), 1),
            else: nil

        # Recent window for trend detection
        recent_n = min(10, max(div(total, 3), 3))
        recent_ops = Enum.take(model_ops, recent_n)
        recent_done = Enum.count(recent_ops, &(&1.status == "done"))
        recent_rate = if recent_n > 0, do: Float.round(recent_done / recent_n, 3), else: nil

        trend = compute_trend(success_rate, recent_rate, total, recent_n)

        # Cost per success
        cost_per_success = compute_model_cost_per_success(model, sector_id)

        {model,
         %{
           success_rate: success_rate,
           avg_quality: avg_quality,
           total_jobs: total,
           trend: trend,
           recent_rate: recent_rate,
           cost_per_success: cost_per_success
         }}
      end)
    end
  end

  defp compute_trend(_baseline_rate, _recent_rate, total, recent_n)
       when total < 8 or recent_n < 3,
       do: :unknown

  defp compute_trend(baseline_rate, recent_rate, _total, _recent_n) do
    diff = recent_rate - baseline_rate

    cond do
      diff < -0.15 -> :declining
      diff > 0.10 -> :improving
      true -> :stable
    end
  end

  defp compute_model_cost_per_success(model, sector_id) do
    costs =
      Archive.filter(:costs, fn c ->
        c[:sector_id] == sector_id and normalize_model(c[:model]) == model
      end)

    total_cost =
      costs
      |> Enum.map(&(&1[:cost_usd] || 0))
      |> Enum.sum()

    # Count successes from ops
    successes =
      Archive.filter(:ops, fn op ->
        op.sector_id == sector_id and
          normalize_model(op[:assigned_model]) == model and
          op.status == "done"
      end)
      |> length()

    if successes > 0, do: Float.round(total_cost / successes, 4), else: nil
  rescue
    _ -> nil
  end

  # -- Private: Recommendations ------------------------------------------------

  defp derive_recommendations(lessons, model_data, confidence) do
    %{
      default_model: pick_default_model(model_data),
      phase_timeout_seconds: derive_phase_timeout(lessons, confidence),
      max_redesign_iterations: derive_max_redesign(lessons, confidence),
      max_validation_fix_attempts: derive_max_fix_attempts(lessons, confidence),
      strategy_count: derive_strategy_count(lessons, confidence),
      threshold_adjustment: derive_threshold_adjustment(lessons, confidence)
    }
  end

  defp pick_default_model(model_data) when map_size(model_data) == 0, do: nil

  defp pick_default_model(model_data) do
    # Pick model with best success_rate among those with enough data (>= 3 jobs)
    model_data
    |> Enum.filter(fn {_model, data} -> data.total_jobs >= 3 and data.trend != :declining end)
    |> Enum.max_by(fn {_model, data} -> data.success_rate end, fn -> nil end)
    |> case do
      {model, _} -> model
      nil -> nil
    end
  end

  defp derive_phase_timeout(%{avg_phase_durations: durations}, confidence)
       when map_size(durations) > 0 do
    avg_duration =
      durations
      |> Map.values()
      |> then(fn vals -> Enum.sum(vals) / max(length(vals), 1) end)

    computed = round(avg_duration * 1.5) |> max(300) |> min(1800)
    blend(computed, @default_phase_timeout, confidence)
  end

  defp derive_phase_timeout(_, _), do: @default_phase_timeout

  defp derive_max_redesign(%{retry_effectiveness: eff}, :high) do
    redesign_rate = Map.get(eff, :different_approach, Map.get(eff, "different_approach"))

    cond do
      is_number(redesign_rate) and redesign_rate > 0.6 -> 3
      is_number(redesign_rate) and redesign_rate < 0.2 -> 1
      true -> @default_max_redesign
    end
  end

  defp derive_max_redesign(_, _), do: @default_max_redesign

  defp derive_max_fix_attempts(%{retry_effectiveness: eff}, :high) do
    fix_rate = Map.get(eff, :improve_quality, Map.get(eff, "improve_quality"))

    cond do
      is_number(fix_rate) and fix_rate > 0.6 -> 3
      is_number(fix_rate) and fix_rate < 0.2 -> 1
      true -> @default_max_fix_attempts
    end
  end

  defp derive_max_fix_attempts(_, _), do: @default_max_fix_attempts

  defp derive_strategy_count(%{quality_baseline: %{avg: avg}}, confidence)
       when is_number(avg) and confidence in [:medium, :high] do
    cond do
      avg > 90 -> 1
      avg < 65 -> 3
      true -> @default_strategy_count_moderate
    end
  end

  defp derive_strategy_count(_, _), do: @default_strategy_count_moderate

  defp derive_threshold_adjustment(%{quality_baseline: %{median: median}}, confidence)
       when is_number(median) and confidence in [:medium, :high] do
    cond do
      median >= 90 -> 0.9
      median < 70 -> 1.1
      true -> @default_threshold_adjustment
    end
  end

  defp derive_threshold_adjustment(_, _), do: @default_threshold_adjustment

  # -- Private: Helpers --------------------------------------------------------

  defp empty_profile(sector_id) do
    %{
      id: sector_id,
      computed_at: DateTime.utc_now(),
      sample_count: 0,
      confidence: :none,
      lessons: %{
        triage_accuracy: %{miss_rate: 0.0, bias: :balanced, adjustments: []},
        common_failures: [],
        success_factors: [],
        quality_baseline: %{avg: nil, p25: nil, median: nil, p75: nil},
        risky_patterns: [],
        avg_phase_durations: %{},
        retry_effectiveness: %{},
        merge_success_rate: %{rate: nil, sample_count: 0, reverted_count: 0, trend: :unknown}
      },
      model_data: %{},
      recommendations: %{
        default_model: nil,
        phase_timeout_seconds: @default_phase_timeout,
        max_redesign_iterations: @default_max_redesign,
        max_validation_fix_attempts: @default_max_fix_attempts,
        strategy_count: @default_strategy_count_moderate,
        threshold_adjustment: @default_threshold_adjustment
      },
      prompt_context: ""
    }
  end

  defp stale?(computed_at) do
    age_minutes = DateTime.diff(DateTime.utc_now(), computed_at, :second) / 60
    age_minutes > @stale_minutes
  end

  defp extract_risky_patterns(common_failures, triage_accuracy) do
    patterns = []

    # High-frequency failure types become risky patterns
    patterns =
      common_failures
      |> Enum.filter(&(&1.frequency > 0.2))
      |> Enum.reduce(patterns, fn f, acc ->
        ["#{f.type} failures (#{round(f.frequency * 100)}%): #{f.top_cause}" | acc]
      end)

    # Triage bias becomes a risky pattern
    patterns =
      case triage_accuracy.bias do
        :under_estimates ->
          [
            "Triage under-estimates complexity — simple tasks often need more resources"
            | patterns
          ]

        :over_estimates ->
          ["Triage over-estimates complexity — could save tokens with lighter models" | patterns]

        _ ->
          patterns
      end

    Enum.reverse(patterns)
  end

  defp normalize_model(model), do: GiTF.Runtime.ModelResolver.normalize_key(model)

  defp round_or_nil(nil), do: nil
  defp round_or_nil(n) when is_number(n), do: round(n)
end
