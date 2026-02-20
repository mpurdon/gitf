defmodule Hive.Config.Thresholds do
  @moduledoc """
  Central module for all tunable thresholds and limits.

  Reads from `config.toml` under the `[thresholds]` section with sensible
  defaults. Operators can tune the dark factory without recompiling.

  ## Config example (config.toml)

      [thresholds]
      lock_stale_seconds = 5
      lock_steal_attempts = 500
      drone_poll_interval_ms = 30000
      queen_max_retries = 3
      waggle_stale_seconds = 30
      alert_quest_stuck_seconds = 1800
      alert_quality_drop = 70
      alert_cost_spike_multiplier = 2.0
      alert_failure_rate = 0.3
      context_warning_pct = 0.40
      context_critical_pct = 0.45
      context_max_pct = 0.50
      circuit_breaker_threshold = 5
      circuit_breaker_reset_ms = 30000
      budget_downgrade_pct = 0.30
  """

  @defaults %{
    lock_stale_seconds: 5,
    lock_steal_attempts: 500,
    drone_poll_interval_ms: 30_000,
    queen_max_retries: 3,
    waggle_stale_seconds: 30,
    alert_quest_stuck_seconds: 1800,
    alert_quality_drop: 70,
    alert_cost_spike_multiplier: 2.0,
    alert_failure_rate: 0.3,
    context_warning_pct: 0.40,
    context_critical_pct: 0.45,
    context_max_pct: 0.50,
    circuit_breaker_threshold: 5,
    circuit_breaker_reset_ms: 30_000,
    budget_downgrade_pct: 0.30
  }

  @doc "Get a threshold value by key. Returns the configured value or default."
  @spec get(atom()) :: term()
  def get(key) when is_map_key(@defaults, key) do
    case read_from_config(key) do
      nil -> Map.fetch!(@defaults, key)
      value -> value
    end
  end

  @doc "Get a threshold value with an explicit fallback."
  @spec get(atom(), term()) :: term()
  def get(key, default) do
    case read_from_config(key) do
      nil -> default
      value -> value
    end
  end

  @doc "Returns all default threshold values."
  @spec defaults() :: map()
  def defaults, do: @defaults

  defp read_from_config(key) do
    string_key = Atom.to_string(key)
    Hive.Config.Provider.get([:thresholds, String.to_atom(string_key)])
  rescue
    _ -> nil
  end
end
