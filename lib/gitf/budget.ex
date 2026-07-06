defmodule GiTF.Budget do
  @moduledoc """
  Cost budget tracking and circuit-breaking for missions.

  Reads the per-mission budget from config and compares against
  actual spending tracked in `GiTF.Costs`. Pure context module.
  """

  @default_budget_usd 10.0
  @default_daily_budget_usd 100.0
  @rolling_window_seconds 24 * 60 * 60

  @doc """
  Checks whether a mission is within budget.

  Returns `{:ok, remaining}` or `{:error, :budget_exceeded, spent}`.
  """
  @spec check(String.t()) :: {:ok, float()} | {:error, :budget_exceeded, float()}
  def check(mission_id) do
    budget = budget_for(mission_id)
    spent = spent_for(mission_id)
    remaining = Float.round(budget - spent, 6)

    if remaining >= 0 do
      {:ok, remaining}
    else
      {:error, :budget_exceeded, spent}
    end
  end

  @doc "Returns the effective budget for a mission (override > config > default)."
  @spec budget_for(String.t()) :: float()
  def budget_for(mission_id) do
    # Check for watchdog-escalated budget override on the mission record first
    case GiTF.Archive.get(:missions, mission_id) do
      %{budget_override: override} when is_number(override) and override > 0 ->
        override * 1.0

      _ ->
        config_budget()
    end
  end

  @doc "Returns the base budget from config (ignoring mission overrides)."
  @spec config_budget() :: float()
  def config_budget do
    case GiTF.Config.Provider.get([:costs, :budget_usd]) do
      val when is_number(val) and val > 0 -> val * 1.0
      _ -> @default_budget_usd
    end
  end

  @doc """
  Factory-wide daily spend cap (rolling 24h) from config.

  This is the global safety ceiling that per-mission budgets sit beneath —
  it bounds total spend across *all* missions and unbounded concurrency.
  """
  @spec daily_budget() :: float()
  def daily_budget do
    case GiTF.Config.Provider.get([:costs, :daily_budget_usd]) do
      val when is_number(val) and val > 0 -> val * 1.0
      _ -> @default_daily_budget_usd
    end
  end

  @doc "Total USD spent across all missions within the rolling 24h window."
  @spec global_spent() :: float()
  def global_spent do
    cutoff = DateTime.add(DateTime.utc_now(), -@rolling_window_seconds, :second)

    GiTF.Archive.all(:costs)
    |> Enum.filter(fn cost ->
      case Map.get(cost, :recorded_at) do
        %DateTime{} = ts -> DateTime.compare(ts, cutoff) != :lt
        # No timestamp: count it (fail-safe — err toward including spend).
        _ -> true
      end
    end)
    |> GiTF.Costs.total()
  end

  @doc """
  Fail-closed factory-wide budget check. Refuses new work once rolling-24h
  spend reaches the daily cap.

  Returns `{:ok, remaining}` or `{:error, :daily_budget_exceeded, spent}`.
  """
  @spec global_check() :: {:ok, float()} | {:error, :daily_budget_exceeded, float()}
  def global_check do
    cap = daily_budget()
    spent = global_spent()

    if spent < cap do
      {:ok, Float.round(cap - spent, 6)}
    else
      {:error, :daily_budget_exceeded, spent}
    end
  end

  @doc "Returns total USD spent for all ghosts in a mission."
  @spec spent_for(String.t()) :: float()
  def spent_for(mission_id) do
    mission_id
    |> GiTF.Costs.for_quest()
    |> GiTF.Costs.total()
  end

  @doc "Returns remaining budget for a mission."
  @spec remaining(String.t()) :: float()
  def remaining(mission_id) do
    Float.round(budget_for(mission_id) - spent_for(mission_id), 6)
  end

  @doc "Returns true if the mission has exceeded its budget."
  @spec exceeded?(String.t()) :: boolean()
  def exceeded?(mission_id) do
    spent_for(mission_id) > budget_for(mission_id)
  end

  @doc """
  Pre-flight budget check before starting a mission.

  Estimates the remaining mission cost based on pending op count and model tier,
  then compares against remaining budget.

  Returns `:ok`, `{:warn, estimated, remaining}`, or `{:error, :would_exceed, estimated, remaining}`.
  """
  # Warn when estimated cost exceeds this fraction of remaining budget
  @warn_threshold 0.7

  @spec preflight_check(String.t()) ::
          :ok | {:warn, float(), float()} | {:error, :would_exceed, float(), float()}
  def preflight_check(mission_id) do
    remaining = remaining(mission_id)
    estimated = estimate_remaining_cost(mission_id)

    cond do
      estimated > remaining ->
        {:error, :would_exceed, estimated, remaining}

      estimated > remaining * @warn_threshold ->
        {:warn, estimated, remaining}

      true ->
        :ok
    end
  end

  # Estimate cost for pending ops based on their assigned model tier
  @cost_per_tier %{
    "fast" => 0.05,
    "general" => 0.25,
    "thinking" => 1.50
  }

  defp estimate_remaining_cost(mission_id) do
    case GiTF.Archive.get(:missions, mission_id) do
      nil ->
        # No mission record yet — estimate a single general op
        @cost_per_tier["general"]

      mission ->
        ops = Map.get(mission, :ops, [])
        pending = Enum.filter(ops, &(&1.status in ["pending", "assigned", "running"]))

        if pending == [] do
          # Mission hasn't created ops yet — estimate from planning artifact
          estimate_from_plan(mission_id)
        else
          Enum.reduce(pending, 0.0, fn op, acc ->
            tier = tier_from_model(Map.get(op, :assigned_model, ""))
            acc + Map.get(@cost_per_tier, tier, @cost_per_tier["general"])
          end)
        end
    end
  end

  defp estimate_from_plan(mission_id) do
    case GiTF.Missions.get_artifact(mission_id, "planning") do
      specs when is_list(specs) and specs != [] ->
        Enum.reduce(specs, 0.0, fn spec, acc ->
          tier = Map.get(spec, "model_recommendation", "general")
          acc + Map.get(@cost_per_tier, tier, @cost_per_tier["general"])
        end)

      _ ->
        # No plan yet — conservative estimate of ~7 general-tier ops (impl + phases)
        7 * @cost_per_tier["general"]
    end
  end

  defp tier_from_model(model_id) when is_binary(model_id) do
    cond do
      String.contains?(model_id, "flash") -> "fast"
      String.contains?(model_id, "thinking") or String.contains?(model_id, "opus") -> "thinking"
      true -> "general"
    end
  end

  defp tier_from_model(_), do: "general"
end
