defmodule Hive.Reputation do
  @moduledoc """
  Reputation system for models, councils, and experts.

  Computes reputation scores from historical job/quest data and caches
  them in the Store. Scores go stale after 30 minutes and are lazily
  recomputed on next access.
  """

  alias Hive.Store

  @stale_minutes 30

  # -- Model Reputation ------------------------------------------------------

  @doc """
  Returns reputation data for a model on a given job type.

  Computed from historical Jobs/Costs/Quality data:
  - success_rate: fraction of jobs completed successfully
  - avg_quality: average verification score (0-100)
  - cost_efficiency: average cost per successful job
  - total_jobs: sample size

  Returns a map or `nil` if no data.
  """
  @spec model_reputation(String.t(), atom()) :: map() | nil
  def model_reputation(model, job_type) do
    key = "model:#{model}:#{job_type}"

    case get_cached(:model_reputation, key) do
      {:ok, rep} -> rep
      :stale -> compute_and_cache_model_rep(model, job_type, key)
    end
  end

  defp compute_and_cache_model_rep(model, job_type, key) do
    jobs =
      Store.filter(:jobs, fn j ->
        normalize_model(j[:assigned_model]) == normalize_model(model) and
          j[:job_type] == job_type
      end)

    if jobs == [] do
      nil
    else
      done = Enum.count(jobs, &(&1.status == "done"))
      total = length(jobs)

      quality_scores =
        jobs
        |> Enum.filter(&(&1.status == "done" and is_number(Map.get(&1, :quality_score))))
        |> Enum.map(& &1.quality_score)

      avg_quality =
        if quality_scores == [],
          do: nil,
          else: Enum.sum(quality_scores) / length(quality_scores)

      rep = %{
        model: model,
        job_type: job_type,
        success_rate: if(total > 0, do: done / total, else: 0.0),
        avg_quality: avg_quality,
        total_jobs: total,
        computed_at: DateTime.utc_now()
      }

      cache_put(:model_reputation, key, rep)
      rep
    end
  end

  # -- Council Reputation ----------------------------------------------------

  @doc """
  Returns reputation for a council (quest success rate).
  """
  @spec council_reputation(String.t()) :: map() | nil
  def council_reputation(council_id) do
    key = "council:#{council_id}"

    case get_cached(:council_reputation, key) do
      {:ok, rep} -> rep
      :stale -> compute_and_cache_council_rep(council_id, key)
    end
  end

  defp compute_and_cache_council_rep(council_id, key) do
    quests =
      Store.filter(:quests, fn q ->
        Map.get(q, :council_id) == council_id
      end)

    if quests == [] do
      nil
    else
      completed = Enum.count(quests, &(&1.status == "completed"))
      total = length(quests)

      rep = %{
        council_id: council_id,
        success_rate: if(total > 0, do: completed / total, else: 0.0),
        total_quests: total,
        computed_at: DateTime.utc_now()
      }

      cache_put(:council_reputation, key, rep)
      rep
    end
  end

  # -- Expert Reputation -----------------------------------------------------

  @doc """
  Returns reputation for an expert key.
  """
  @spec expert_reputation(String.t()) :: map() | nil
  def expert_reputation(expert_key) do
    key = "expert:#{expert_key}"

    case get_cached(:expert_reputation, key) do
      {:ok, rep} -> rep
      :stale -> compute_and_cache_expert_rep(expert_key, key)
    end
  end

  defp compute_and_cache_expert_rep(expert_key, key) do
    jobs =
      Store.filter(:jobs, fn j ->
        experts = Map.get(j, :council_experts) || []
        is_list(experts) and expert_key in experts
      end)

    if jobs == [] do
      nil
    else
      done = Enum.count(jobs, &(&1.status == "done"))
      total = length(jobs)

      rep = %{
        expert_key: expert_key,
        success_rate: if(total > 0, do: done / total, else: 0.0),
        total_jobs: total,
        computed_at: DateTime.utc_now()
      }

      cache_put(:expert_reputation, key, rep)
      rep
    end
  end

  # -- Recommendations -------------------------------------------------------

  @doc """
  Recommends the best model for a job type and complexity based on reputation.

  Falls back to ModelSelector if no reputation data exists.
  """
  @spec recommend_model(atom(), atom()) :: String.t()
  def recommend_model(job_type, complexity) do
    models = ["opus", "sonnet", "haiku"]

    scored =
      models
      |> Enum.map(fn model ->
        rep = model_reputation(model, job_type)
        score = if rep, do: rep.success_rate * (rep.total_jobs |> min(20)) / 20, else: 0.0
        {model, score}
      end)
      |> Enum.filter(fn {_, score} -> score > 0 end)
      |> Enum.sort_by(fn {_, score} -> score end, :desc)

    case scored do
      [{model, _} | _] -> model
      [] -> Hive.Runtime.ModelSelector.select_model_for_job(job_type, complexity)
    end
  end

  @doc """
  Returns experts sorted by composite reputation score.

  Options:
  - `:limit` - max results (default 10)
  """
  @spec rank_experts(keyword()) :: [map()]
  def rank_experts(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    # Collect all unique expert keys from jobs
    expert_keys =
      Store.all(:jobs)
      |> Enum.flat_map(fn j ->
        case Map.get(j, :council_experts) do
          experts when is_list(experts) -> experts
          _ -> []
        end
      end)
      |> Enum.uniq()

    expert_keys
    |> Enum.map(fn key ->
      rep = expert_reputation(key)
      score = if rep, do: rep.success_rate, else: 0.0
      %{expert_key: key, score: score, reputation: rep}
    end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  @doc """
  Recomputes reputations relevant to a completed/failed job.

  Called by Queen after verification pass/fail.
  """
  @spec update_after_job(String.t()) :: :ok
  def update_after_job(job_id) do
    case Hive.Jobs.get(job_id) do
      {:ok, job} ->
        model = normalize_model(job[:assigned_model])
        job_type = job[:job_type]

        if not is_nil(model) and not is_nil(job_type) do
          key = "model:#{model}:#{job_type}"
          invalidate(:model_reputation, key)
        end

        experts = Map.get(job, :council_experts) || []

        Enum.each(experts, fn expert_key ->
          invalidate(:expert_reputation, "expert:#{expert_key}")
        end)

        :ok

      _ ->
        :ok
    end
  end

  # -- Cache Helpers ---------------------------------------------------------

  defp get_cached(collection, key) do
    case Store.get(collection, key) do
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
    Store.put(collection, record)
  rescue
    _ -> :ok
  end

  defp invalidate(collection, key) do
    Store.delete(collection, key)
  rescue
    _ -> :ok
  end

  defp normalize_model(nil), do: nil
  defp normalize_model(model) when is_binary(model) do
    model
    |> String.replace("claude-", "")
    |> String.split("-")
    |> hd()
  end
  defp normalize_model(model) when is_atom(model), do: normalize_model(Atom.to_string(model))
end
