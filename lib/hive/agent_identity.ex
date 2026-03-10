defmodule Hive.AgentIdentity do
  @moduledoc """
  Persistent per-model learning profiles that track what each model excels at
  and struggles with. Survives across quests.

  This is a pure context module -- no GenServer, no state, just data
  transformations against the Store. Fed by `Hive.Drone.Scoring` data,
  consumed by `Hive.Runtime.ModelSelector` for informed model selection.

  Each identity is a living CV for a model: total jobs worked, pass rates
  by job type, trait-based strengths/weaknesses with confidence scores,
  and a rolling window of recent job summaries.
  """

  alias Hive.Store

  @collection :agent_identities
  @max_recent_jobs 20
  @confidence_growth 0.1
  @confidence_cap 1.0

  # -- Public API ------------------------------------------------------------

  @doc """
  Fetches an identity by model name.

  Returns `{:ok, identity}` or `{:error, :not_found}`.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(model) when is_binary(model) do
    case Store.find_one(@collection, &(&1.model == model)) do
      nil -> {:error, :not_found}
      identity -> {:ok, identity}
    end
  end

  @doc """
  Gets an existing identity or creates a fresh one with default values.
  """
  @spec get_or_create(String.t()) :: {:ok, map()}
  def get_or_create(model) when is_binary(model) do
    case get(model) do
      {:ok, identity} -> {:ok, identity}
      {:error, :not_found} -> Store.insert(@collection, new_identity(model))
    end
  end

  @doc """
  Updates an identity from a score map produced by `Hive.Drone.Scoring.score/2`.

  Increments job counts, recalculates running averages, merges trait
  confidence, and maintains the recent jobs window.
  """
  @spec update_from_score(String.t(), map()) :: {:ok, map()}
  def update_from_score(model, score) when is_binary(model) and is_map(score) do
    {:ok, identity} = get_or_create(model)

    identity
    |> increment_job_counts(score)
    |> merge_traits(:strengths, Map.get(score, :strengths, []))
    |> merge_traits(:weaknesses, Map.get(score, :weaknesses, []))
    |> recalculate_avg_scores(score)
    |> update_job_type_stats(score)
    |> append_recent_job(score)
    |> Map.put(:last_updated, DateTime.utc_now() |> DateTime.truncate(:second))
    |> then(&Store.put(@collection, &1))
  end

  @doc """
  Recommends the best model for a job type from a list of available models.

  Picks the model with the highest pass rate for the given job type.
  Falls back to overall pass rate when no job-type-specific data exists.
  Returns `{:error, :no_data}` when no identities exist for any model.
  """
  @spec recommend_model_for(String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, :no_data}
  def recommend_model_for(job_type, available_models)
      when is_binary(job_type) and is_list(available_models) do
    identities =
      available_models
      |> Enum.map(fn model -> {model, get(model)} end)
      |> Enum.filter(fn {_m, result} -> match?({:ok, _}, result) end)
      |> Enum.map(fn {model, {:ok, id}} -> {model, id} end)
      |> Enum.filter(fn {_m, id} -> id.total_jobs > 0 end)

    case identities do
      [] ->
        {:error, :no_data}

      candidates ->
        best = pick_best_for_job_type(candidates, job_type)
        {:ok, best}
    end
  end

  @doc """
  Returns a human-readable markdown summary of a model's identity/CV.
  """
  @spec summary(String.t()) :: String.t()
  def summary(model) when is_binary(model) do
    case get(model) do
      {:error, :not_found} ->
        "No identity data for model `#{model}`."

      {:ok, id} ->
        format_summary(id)
    end
  end

  @doc """
  Lists all identities sorted by total_jobs descending.
  """
  @spec list() :: [map()]
  def list do
    Store.all(@collection)
    |> Enum.sort_by(& &1.total_jobs, :desc)
  end

  # -- Private: identity construction ----------------------------------------

  defp new_identity(model) do
    %{
      model: model,
      total_jobs: 0,
      total_passed: 0,
      total_failed: 0,
      strengths: [],
      weaknesses: [],
      best_job_types: [],
      worst_job_types: [],
      avg_scores: %{correctness: 0.0, completeness: 0.0, code_quality: 0.0, efficiency: 0.0},
      recent_jobs: [],
      last_updated: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  # -- Private: update pipeline ----------------------------------------------

  defp increment_job_counts(identity, score) do
    passed? = Map.get(score, :passed, false)

    identity
    |> Map.update!(:total_jobs, &(&1 + 1))
    |> then(fn id ->
      if passed?,
        do: Map.update!(id, :total_passed, &(&1 + 1)),
        else: Map.update!(id, :total_failed, &(&1 + 1))
    end)
  end

  defp merge_traits(identity, field, new_traits) when is_list(new_traits) do
    existing = Map.get(identity, field, [])

    merged =
      Enum.reduce(new_traits, existing, fn trait_name, acc ->
        case Enum.find_index(acc, &(&1.trait == trait_name)) do
          nil ->
            acc ++ [%{trait: trait_name, confidence: @confidence_growth}]

          idx ->
            List.update_at(acc, idx, fn entry ->
              %{entry | confidence: min(entry.confidence + @confidence_growth, @confidence_cap)}
            end)
        end
      end)

    Map.put(identity, field, merged)
  end

  defp recalculate_avg_scores(identity, score) do
    score_values = Map.get(score, :scores, %{})
    n = identity.total_jobs

    new_avgs =
      Map.new(identity.avg_scores, fn {key, current_avg} ->
        new_val = Map.get(score_values, key, current_avg)
        # Running average: ((old_avg * (n-1)) + new_val) / n
        updated = if n > 1, do: (current_avg * (n - 1) + new_val) / n, else: new_val / 1.0
        {key, Float.round(updated, 1)}
      end)

    %{identity | avg_scores: new_avgs}
  end

  defp update_job_type_stats(identity, score) do
    job_type = Map.get(score, :job_type, "general")
    passed? = Map.get(score, :passed, false)

    # Rebuild stats from recent_jobs + this new score for accuracy
    all_type_stats =
      (identity.recent_jobs ++ [%{type: job_type, passed: passed?}])
      |> Enum.group_by(& &1.type)
      |> Enum.map(fn {type, entries} ->
        count = length(entries)
        pass_count = Enum.count(entries, & &1.passed)
        pass_rate = if count > 0, do: Float.round(pass_count / count, 3), else: 0.0
        %{type: type, pass_rate: pass_rate, count: count}
      end)
      |> Enum.sort_by(& &1.pass_rate, :desc)

    best = Enum.take(all_type_stats, 3)
    worst = all_type_stats |> Enum.reverse() |> Enum.take(3)

    %{identity | best_job_types: best, worst_job_types: worst}
  end

  defp append_recent_job(identity, score) do
    entry = %{
      job_id: Map.get(score, :job_id),
      type: Map.get(score, :job_type, "general"),
      passed: Map.get(score, :passed, false),
      timestamp: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    recent =
      (identity.recent_jobs ++ [entry])
      |> Enum.take(-@max_recent_jobs)

    %{identity | recent_jobs: recent}
  end

  # -- Private: model recommendation ----------------------------------------

  defp pick_best_for_job_type(candidates, job_type) do
    # Try job-type-specific pass rate first
    type_scored =
      candidates
      |> Enum.map(fn {model, id} ->
        type_stat = Enum.find(id.best_job_types ++ id.worst_job_types, &(&1.type == job_type))

        type_pass_rate =
          if type_stat && type_stat.count > 0,
            do: type_stat.pass_rate,
            else: nil

        {model, type_pass_rate, overall_pass_rate(id)}
      end)

    # If any candidate has job-type-specific data, use it
    with_type_data = Enum.filter(type_scored, fn {_, tpr, _} -> tpr != nil end)

    if with_type_data != [] do
      {best, _, _} = Enum.max_by(with_type_data, fn {_, tpr, _} -> tpr end)
      best
    else
      # Fall back to overall pass rate
      {best, _, _} = Enum.max_by(type_scored, fn {_, _, opr} -> opr end)
      best
    end
  end

  defp overall_pass_rate(%{total_jobs: 0}), do: 0.0

  defp overall_pass_rate(%{total_passed: passed, total_jobs: total}) do
    passed / total
  end

  # -- Private: summary formatting -------------------------------------------

  defp format_summary(id) do
    pass_rate = if id.total_jobs > 0, do: Float.round(id.total_passed / id.total_jobs * 100, 1), else: 0.0

    strengths_text = format_traits(id.strengths)
    weaknesses_text = format_traits(id.weaknesses)
    best_types_text = format_job_types(id.best_job_types)
    worst_types_text = format_job_types(id.worst_job_types)

    """
    # #{id.model}

    **Jobs:** #{id.total_jobs} total | #{id.total_passed} passed | #{id.total_failed} failed | #{pass_rate}% pass rate

    **Average Scores:**
    - Correctness: #{id.avg_scores.correctness}
    - Completeness: #{id.avg_scores.completeness}
    - Code Quality: #{id.avg_scores.code_quality}
    - Efficiency: #{id.avg_scores.efficiency}

    **Strengths:** #{strengths_text}
    **Weaknesses:** #{weaknesses_text}

    **Best Job Types:** #{best_types_text}
    **Worst Job Types:** #{worst_types_text}

    _Last updated: #{id.last_updated}_
    """
  end

  defp format_traits([]), do: "none recorded"

  defp format_traits(traits) do
    traits
    |> Enum.sort_by(& &1.confidence, :desc)
    |> Enum.map(fn t -> "#{t.trait} (#{Float.round(t.confidence * 100, 0)}%)" end)
    |> Enum.join(", ")
  end

  defp format_job_types([]), do: "none recorded"

  defp format_job_types(types) do
    types
    |> Enum.map(fn t -> "#{t.type} (#{Float.round(t.pass_rate * 100, 0)}%, n=#{t.count})" end)
    |> Enum.join(", ")
  end
end
