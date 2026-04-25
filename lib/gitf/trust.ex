defmodule GiTF.Trust do
  @moduledoc """
  Trust system for models.

  Computes trust scores from historical op/mission data and caches
  them in the Archive. Scores go stale after 30 minutes and are lazily
  recomputed on next access.
  """

  alias GiTF.Archive

  @stale_minutes 30

  # -- Model Trust ------------------------------------------------------

  @doc """
  Returns trust data for a model on a given op type.

  Computed from historical Jobs/Costs/Quality data:
  - success_rate: fraction of ops completed successfully
  - avg_quality: average verification score (0-100)
  - cost_efficiency: average cost per successful op
  - total_jobs: sample size

  Returns a map or `nil` if no data.
  """
  @spec model_reputation(String.t(), atom()) :: map() | nil
  def model_reputation(model, op_type) do
    key = "model:#{model}:#{op_type}"

    case get_cached(:model_reputation, key) do
      {:ok, rep} -> rep
      :stale -> compute_and_cache_model_rep(model, op_type, key)
    end
  end

  defp compute_and_cache_model_rep(model, op_type, key) do
    ops =
      Archive.filter(:ops, fn j ->
        normalize_model(j[:assigned_model]) == normalize_model(model) and
          j[:op_type] == op_type
      end)

    if ops == [] do
      nil
    else
      done = Enum.count(ops, &(&1.status == "done"))
      regression_count = Enum.count(ops, &(Map.get(&1, :regression_detected, false) == true))
      adjusted_done = max(done - regression_count * 0.5, 0)
      total = length(ops)

      quality_scores =
        ops
        |> Enum.filter(&(&1.status == "done" and is_number(Map.get(&1, :quality_score))))
        |> Enum.map(& &1.quality_score)

      avg_quality =
        if quality_scores == [],
          do: nil,
          else: Enum.sum(quality_scores) / length(quality_scores)

      rep = %{
        model: model,
        op_type: op_type,
        success_rate: if(total > 0, do: adjusted_done / total, else: 0.0),
        avg_quality: avg_quality,
        total_jobs: total,
        computed_at: DateTime.utc_now()
      }

      cache_put(:model_reputation, key, rep)
      rep
    end
  end

  # -- Recommendations -------------------------------------------------------

  @doc """
  Recommends the best model for a op type and complexity based on trust.

  Falls back to ModelSelector if no trust data exists.
  """
  @spec recommend_model(atom(), atom()) :: String.t()
  def recommend_model(op_type, complexity) do
    models = ["opus", "sonnet", "haiku"]

    scored =
      models
      |> Enum.map(fn model ->
        rep = model_reputation(model, op_type)
        score = if rep, do: rep.success_rate * (rep.total_jobs |> min(20)) / 20, else: 0.0
        {model, score}
      end)
      |> Enum.filter(fn {_, score} -> score > 0 end)
      |> Enum.sort_by(fn {_, score} -> score end, :desc)

    case scored do
      [{model, _} | _] -> model
      [] -> GiTF.Runtime.ModelSelector.select_model_for_job(op_type, complexity)
    end
  end

  @doc """
  Recomputes reputations relevant to a completed/failed op.

  Called by Major after verification pass/fail.
  """
  @spec update_after_job(String.t()) :: :ok
  def update_after_job(op_id) do
    case GiTF.Ops.get(op_id) do
      {:ok, op} ->
        model = normalize_model(op[:assigned_model])
        op_type = op[:op_type]

        if not is_nil(model) and not is_nil(op_type) do
          key = "model:#{model}:#{op_type}"
          invalidate(:model_reputation, key)
        end

        :ok

      _ ->
        :ok
    end
  end

  # -- Regression Penalty ----------------------------------------------------

  @doc """
  Applies a regression penalty to all non-phase ops of a mission.

  Marks ops with `regression_detected: true` and invalidates their
  trust cache so the penalty is reflected in future computations.
  """
  @spec apply_regression_penalty(String.t()) :: :ok
  def apply_regression_penalty(mission_id) do
    ops = GiTF.Ops.list(mission_id: mission_id)

    ops
    |> Enum.reject(& &1[:phase_job])
    |> Enum.each(fn op ->
      updated = Map.put(op, :regression_detected, true)
      Archive.put(:ops, updated)

      # Invalidate trust cache for this op's model
      model = normalize_model(op[:assigned_model])
      op_type = op[:op_type]

      if not is_nil(model) and not is_nil(op_type) do
        invalidate(:model_reputation, "model:#{model}:#{op_type}")
      end
    end)

    :ok
  end

  # -- Cache Helpers ---------------------------------------------------------

  defp get_cached(collection, key) do
    case Archive.get(collection, key) do
      nil ->
        :stale

      %{computed_at: computed_at} = rep ->
        age_minutes = DateTime.diff(DateTime.utc_now(), computed_at, :second) / 60

        if age_minutes > @stale_minutes,
          do: :stale,
          else: {:ok, rep}

      _ ->
        :stale
    end
  end

  defp cache_put(collection, key, data) do
    record = Map.put(data, :id, key)
    Archive.put(collection, record)
  rescue
    _ -> :ok
  end

  defp invalidate(collection, key) do
    Archive.delete(collection, key)
  rescue
    _ -> :ok
  end

  defp normalize_model(model), do: GiTF.Runtime.ModelResolver.normalize_key(model)

  # -- Merge-outcome reputation ----------------------------------------------

  @merge_window_days 30

  @doc """
  Rolling merge-success rate for a sector, computed from
  `:mission_outcomes`. Returns `nil` when there are no terminal outcomes
  in the window. Cached under the existing `:model_reputation` collection
  to reuse the stale/invalidate plumbing.

  Window: last 30 days. Terminal categories are `:merged_clean`,
  `:merged_reverted`, `:closed_unmerged`, `:merged_broke_main`. Rate is
  `merged_clean / terminal`.
  """
  @spec sector_merge_rate(String.t()) :: map() | nil
  def sector_merge_rate(sector_id) when is_binary(sector_id) do
    key = "sector:#{sector_id}:merge"

    case get_cached(:model_reputation, key) do
      {:ok, rep} -> rep
      :stale -> compute_sector_merge_rate(sector_id, key)
    end
  end

  @doc """
  Rolling merge-success rate for a given model across all sectors. Uses
  the ops table to attribute outcomes to the model that implemented the
  mission's ops. Nil when there are no terminal outcomes.
  """
  @spec model_merge_rate(String.t()) :: map() | nil
  def model_merge_rate(model) when is_binary(model) do
    key = "model:#{normalize_model(model)}:merge"

    case get_cached(:model_reputation, key) do
      {:ok, rep} -> rep
      :stale -> compute_model_merge_rate(model, key)
    end
  end

  @doc """
  Invalidates the merge-rate caches for a given mission's sector
  (and the set of models that implemented its ops). Called by
  `Outcomes.Tracker` when an outcome reaches a terminal category.
  """
  @spec invalidate_merge_cache(map()) :: :ok
  def invalidate_merge_cache(mission) when is_map(mission) do
    case Map.get(mission, :sector_id) do
      sid when is_binary(sid) -> invalidate(:model_reputation, "sector:#{sid}:merge")
      _ -> :ok
    end

    for op <- Map.get(mission, :ops, []) || [] do
      case normalize_model(op[:assigned_model]) do
        nil -> :ok
        model -> invalidate(:model_reputation, "model:#{model}:merge")
      end
    end

    :ok
  end

  defp compute_sector_merge_rate(sector_id, key) do
    outcomes = terminal_outcomes_for_sector(sector_id)

    if outcomes == [] do
      nil
    else
      merged = Enum.count(outcomes, &(&1.outcome_category == :merged_clean))
      reverted = Enum.count(outcomes, &(&1.outcome_category == :merged_reverted))
      total = length(outcomes)

      rep = %{
        sector_id: sector_id,
        rate: merged / total,
        sample_count: total,
        reverted_count: reverted,
        window_days: @merge_window_days,
        computed_at: DateTime.utc_now()
      }

      cache_put(:model_reputation, key, rep)
      rep
    end
  end

  defp compute_model_merge_rate(model, key) do
    normalized = normalize_model(model)

    mission_ids_for_model =
      Archive.filter(:ops, fn op ->
        normalize_model(op[:assigned_model]) == normalized and
          Map.get(op, :phase_job, false) == false
      end)
      |> MapSet.new(& &1.mission_id)

    outcomes =
      GiTF.Outcomes.terminal_outcomes()
      |> Enum.filter(fn o ->
        MapSet.member?(mission_ids_for_model, o.mission_id) and within_window?(o)
      end)

    if outcomes == [] do
      nil
    else
      merged = Enum.count(outcomes, &(&1.outcome_category == :merged_clean))
      total = length(outcomes)

      rep = %{
        model: normalized,
        rate: merged / total,
        sample_count: total,
        window_days: @merge_window_days,
        computed_at: DateTime.utc_now()
      }

      cache_put(:model_reputation, key, rep)
      rep
    end
  end

  defp terminal_outcomes_for_sector(sector_id) do
    GiTF.Outcomes.terminal_outcomes(sector_id)
    |> Enum.filter(&within_window?/1)
  end

  defp within_window?(outcome) do
    case Map.get(outcome, :updated_at) do
      %DateTime{} = t ->
        DateTime.diff(DateTime.utc_now(), t, :second) <= @merge_window_days * 24 * 3600

      _ ->
        true
    end
  end
end
