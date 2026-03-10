defmodule Hive.Budget do
  @moduledoc """
  Cost budget tracking and circuit-breaking for quests.

  Reads the per-quest budget from config and compares against
  actual spending tracked in `Hive.Costs`. Pure context module.
  """

  @default_budget_usd 10.0

  @doc """
  Checks whether a quest is within budget.

  Returns `{:ok, remaining}` or `{:error, :budget_exceeded, spent}`.
  """
  @spec check(String.t()) :: {:ok, float()} | {:error, :budget_exceeded, float()}
  def check(quest_id) do
    budget = budget_for(quest_id)
    spent = spent_for(quest_id)
    remaining = Float.round(budget - spent, 6)

    if remaining >= 0 do
      {:ok, remaining}
    else
      {:error, :budget_exceeded, spent}
    end
  end

  @doc "Returns the effective budget for a quest (override > config > default)."
  @spec budget_for(String.t()) :: float()
  def budget_for(quest_id) do
    # Check for watchdog-escalated budget override on the quest record first
    case Hive.Store.get(:quests, quest_id) do
      %{budget_override: override} when is_number(override) and override > 0 ->
        override * 1.0

      _ ->
        config_budget()
    end
  end

  @doc "Returns the base budget from config (ignoring quest overrides)."
  @spec config_budget() :: float()
  def config_budget do
    case Hive.hive_dir() do
      {:ok, hive_root} ->
        config_path = Path.join([hive_root, ".hive", "config.toml"])

        case Hive.Config.read_config(config_path) do
          {:ok, config} ->
            (get_in(config, ["costs", "budget_usd"]) || @default_budget_usd) * 1.0

          {:error, _} ->
            @default_budget_usd
        end

      {:error, _} ->
        @default_budget_usd
    end
  end

  @doc "Returns total USD spent for all bees in a quest."
  @spec spent_for(String.t()) :: float()
  def spent_for(quest_id) do
    quest_id
    |> Hive.Costs.for_quest()
    |> Hive.Costs.total()
  end

  @doc "Returns remaining budget for a quest."
  @spec remaining(String.t()) :: float()
  def remaining(quest_id) do
    Float.round(budget_for(quest_id) - spent_for(quest_id), 6)
  end

  @doc "Returns true if the quest has exceeded its budget."
  @spec exceeded?(String.t()) :: boolean()
  def exceeded?(quest_id) do
    spent_for(quest_id) > budget_for(quest_id)
  end
end
