defmodule GiTF.Budget do
  @moduledoc """
  Cost budget tracking and circuit-breaking for missions.

  Reads the per-mission budget from config and compares against
  actual spending tracked in `GiTF.Costs`. Pure context module.
  """

  @default_budget_usd 10.0

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
    case GiTF.gitf_dir() do
      {:ok, gitf_root} ->
        config_path = Path.join([gitf_root, ".gitf", "config.toml"])

        case GiTF.Config.read_config(config_path) do
          {:ok, config} ->
            (get_in(config, ["costs", "budget_usd"]) || @default_budget_usd) * 1.0

          {:error, _} ->
            @default_budget_usd
        end

      {:error, _} ->
        @default_budget_usd
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
end
