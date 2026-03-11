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

  defp normalize_model(nil), do: nil
  defp normalize_model(model) when is_binary(model) do
    model
    |> String.split(":")
    |> List.last()
    |> String.replace("claude-", "")
    |> String.split("-")
    |> hd()
  end
  defp normalize_model(model) when is_atom(model), do: normalize_model(Atom.to_string(model))
end
