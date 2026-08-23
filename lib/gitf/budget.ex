defmodule GiTF.Budget do
  @moduledoc """
  Cost budget tracking and circuit-breaking for missions.

  Reads the per-mission budget from config and compares against
  actual spending tracked in `GiTF.Costs`. Pure context module.
  """

  @default_budget_usd 10.0
  # CLI/subscription mode books API-equivalent NOTIONAL dollars at $0
  # marginal cost; this cap is a runaway-loop guard, not a spend limit.
  @default_cli_notional_budget_usd 150.0

  # Subscription streams are rationed in requests, not dollars. These are
  # runaway guards, deliberately generous — they are NOT a mirror of the
  # provider's real limits, which we cannot observe. The point is to stop a
  # loop burning a plan's quota, not to predict when Anthropic will throttle.
  @default_subscription_providers ["cli"]
  @default_usage_window_hours 5
  @default_max_requests 1_500
  @default_max_tokens 0
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

  @doc """
  Returns the base budget from config (ignoring mission overrides).

  `[costs.provider_mission_budgets]` (provider → USD) overrides the flat
  `budget_usd` for the active provider — subscription-billed (cli) missions
  book notional dollars at API-equivalent rates, so a cap tuned for real
  metered spend would strangle them.
  """
  @spec config_budget() :: float()
  def config_budget do
    per_provider =
      case GiTF.Config.Provider.get([:costs, :provider_mission_budgets]) do
        map when is_map(map) -> Map.new(map, fn {k, v} -> {to_string(k), v} end)
        _ -> %{}
      end

    case Map.get(per_provider, active_provider()) do
      val when is_number(val) and val > 0 ->
        val * 1.0

      _ ->
        case GiTF.Config.Provider.get([:costs, :budget_usd]) do
          val when is_number(val) and val > 0 ->
            val * 1.0

          _ ->
            # No config at all: the default must fit the billing model.
            # CLI-mode costs are NOTIONAL (subscription-billed at $0
            # marginal) — the metered default here killed run 24, the
            # campaign's only zero-failure run, at $22.51 "spent". The cap
            # still exists in CLI mode purely as a runaway-loop guard.
            if active_provider() == "cli",
              do: @default_cli_notional_budget_usd,
              else: @default_budget_usd
        end
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

  @doc """
  Daily cap for a specific provider's spend stream.

  Read from `[costs.provider_budgets]` (provider name → USD/day), falling
  back to `daily_budget/0`. This lets metered providers (bedrock, google)
  keep a tight real-dollar cap while subscription-billed streams (cli)
  carry a higher notional cap that still brakes runaways.
  """
  @spec provider_budget(String.t()) :: float()
  def provider_budget(provider) do
    budgets =
      case GiTF.Config.Provider.get([:costs, :provider_budgets]) do
        map when is_map(map) -> Map.new(map, fn {k, v} -> {to_string(k), v} end)
        _ -> %{}
      end

    case Map.get(budgets, provider) do
      val when is_number(val) and val > 0 -> val * 1.0
      _ -> daily_budget()
    end
  end

  @doc """
  The provider whose spend stream new work would add to, derived from the
  execution mode. New spawns are budget-checked against this stream only —
  yesterday's bedrock dollars must not block today's subscription work.
  """
  @spec active_provider() :: String.t()
  def active_provider do
    case GiTF.Runtime.ModelResolver.execution_mode() do
      :cli -> "cli"
      :bedrock -> "bedrock"
      :ollama -> "ollama"
      :api -> GiTF.Runtime.ModelResolver.configured_provider()
    end
  rescue
    _ -> "unknown"
  end

  @doc """
  Classifies a cost record (or model string) into a provider stream.

  Cost records store normalized model specs: metered API paths always carry
  a provider prefix ("bedrock:", "google:", ...) or a bedrock ARN, while the
  Claude Code CLI booking path records bare model names — so bare = "cli".
  """
  @spec provider_of(map() | String.t() | nil) :: String.t()
  def provider_of(%{} = cost), do: provider_of(Map.get(cost, :model))
  def provider_of("arn:aws:bedrock" <> _), do: "bedrock"
  def provider_of("amazon_bedrock:" <> _), do: "bedrock"

  def provider_of(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [prefix, _] -> prefix
      [_] -> "cli"
    end
  end

  def provider_of(_), do: "unknown"

  @doc """
  Total USD spent within the rolling 24h window — across all providers by
  default, or scoped to one provider's stream.
  """
  @spec global_spent(:all | String.t()) :: float()
  def global_spent(provider \\ :all) do
    cutoff = DateTime.add(DateTime.utc_now(), -@rolling_window_seconds, :second)

    GiTF.Archive.all(:costs)
    |> Enum.filter(fn cost ->
      in_window =
        case Map.get(cost, :recorded_at) do
          %DateTime{} = ts -> DateTime.compare(ts, cutoff) != :lt
          # No timestamp: count it (fail-safe — err toward including spend).
          _ -> true
        end

      in_window and (provider == :all or provider_of(cost) == provider)
    end)
    |> GiTF.Costs.total()
  end

  @doc """
  Fail-closed factory-wide budget check for the ACTIVE provider's stream.

  Two layers, both scoped to the active provider:
  - rolling-24h daily cap (velocity brake — bounds burn rate)
  - optional pre-paid credit pool (cumulative ceiling — bounds total spend
    against money already loaded with the provider)

  Returns `{:ok, remaining}` (the tighter of the two layers) or
  `{:error, :daily_budget_exceeded | :credit_pool_exhausted, spent}`.
  """
  @spec global_check() ::
          {:ok, float()}
          | {:error, :daily_budget_exceeded | :credit_pool_exhausted, float()}
  def global_check do
    provider = active_provider()

    if subscription?(provider) do
      subscription_check(provider)
    else
      metered_check(provider)
    end
  end

  defp metered_check(provider) do
    cap = provider_budget(provider)
    spent = global_spent(provider)

    cond do
      spent >= cap ->
        {:error, :daily_budget_exceeded, spent}

      true ->
        case pool_check(provider) do
          {:ok, pool_remaining} -> {:ok, min(Float.round(cap - spent, 6), pool_remaining)}
          error -> error
        end
    end
  end

  @doc """
  Human-readable description of why the active provider is over its limit.

  Dollars for metered providers, requests for subscription ones. The same
  sentence in the wrong unit — "spent $605.25 of $150.00 cap" for work that
  cost nothing — is what turned a runaway guard into an apparent bill.
  """
  @spec limit_description(number()) :: String.t()
  def limit_description(spent) do
    provider = active_provider()

    if subscription?(provider) do
      "#{trunc(spent)} of #{request_limit(provider)} requests in the last " <>
        "#{window_hours(provider)}h on the #{provider} subscription"
    else
      "$#{Float.round(spent * 1.0, 2)} of $#{Float.round(provider_budget(provider), 2)} in the last 24h"
    end
  end

  @doc """
  True when a provider bills a flat subscription rather than per token.

  Dollars are the wrong unit for these: the marginal cost of a call is zero,
  so a dollar cap is a fabricated number. What is real is the provider's
  *usage* limit — Claude Max meters requests in a rolling window, and a
  ChatGPT/Sol account would do the same. Configure via
  `[costs.subscription_providers]`; defaults to the CLI stream.
  """
  @spec subscription?(String.t()) :: boolean()
  def subscription?(provider) do
    case GiTF.Config.Provider.get([:costs, :subscription_providers]) do
      list when is_list(list) -> provider in Enum.map(list, &to_string/1)
      _ -> provider in @default_subscription_providers
    end
  end

  @doc """
  Requests and tokens booked to a provider within its rolling usage window.

  Each cost entry is one model call, so counting entries counts requests —
  the unit subscription plans actually ration.
  """
  @spec usage_in_window(String.t()) :: %{requests: non_neg_integer(), tokens: non_neg_integer()}
  def usage_in_window(provider) do
    cutoff = DateTime.add(DateTime.utc_now(), -window_hours(provider) * 3600, :second)

    entries =
      GiTF.Archive.all(:costs)
      |> Enum.filter(fn c ->
        provider_of(c) == provider and
          match?(%DateTime{}, c[:inserted_at]) and
          DateTime.compare(c[:inserted_at], cutoff) != :lt
      end)

    %{
      requests: length(entries),
      tokens:
        Enum.reduce(entries, 0, fn c, acc ->
          acc + (c[:input_tokens] || 0) + (c[:output_tokens] || 0)
        end)
    }
  end

  # Reported as :daily_budget_exceeded so the three existing callers keep
  # working — what changed is the unit being measured, not the protocol.
  # `spent` carries the request count so operator messages stay truthful.
  defp subscription_check(provider) do
    %{requests: requests, tokens: tokens} = usage_in_window(provider)
    req_cap = request_limit(provider)
    tok_cap = token_limit(provider)

    cond do
      requests >= req_cap -> {:error, :daily_budget_exceeded, requests}
      tok_cap > 0 and tokens >= tok_cap -> {:error, :daily_budget_exceeded, requests}
      true -> {:ok, req_cap - requests}
    end
  end

  @doc "Rolling window, in hours, over which a subscription's usage is counted."
  @spec window_hours(String.t()) :: pos_integer()
  def window_hours(provider),
    do: provider_usage_setting(provider, :window_hours, @default_usage_window_hours)

  @doc "Max model calls allowed within the rolling window."
  @spec request_limit(String.t()) :: pos_integer()
  def request_limit(provider),
    do: provider_usage_setting(provider, :max_requests, @default_max_requests)

  @doc "Max tokens within the window; 0 disables the token check."
  @spec token_limit(String.t()) :: non_neg_integer()
  def token_limit(provider),
    do: provider_usage_setting(provider, :max_tokens, @default_max_tokens)

  defp provider_usage_setting(provider, key, default) do
    with quotas when is_map(quotas) <- GiTF.Config.Provider.get([:costs, :provider_quotas]),
         settings when is_map(settings) <- Map.get(quotas, provider) || Map.get(quotas, :"#{provider}"),
         val when is_number(val) and val > 0 <-
           Map.get(settings, key) || Map.get(settings, to_string(key)) do
      trunc(val)
    else
      _ -> default
    end
  end

  @doc """
  Pre-paid credit pool check for a provider (cumulative, not rolling).

  Config, per provider:

      [costs.credit_pools.anthropic]
      pool_usd = 50.0          # credits loaded with the provider
      since = "2026-08-01"     # accounting anchor: sum bookings from here

  On top-up or reconciliation against the provider's real balance, update
  `pool_usd` and `since` together. Providers with no pool configured pass
  unconditionally (bedrock is post-pay; cli is subscription-billed).
  """
  @spec pool_check(String.t()) :: {:ok, float()} | {:error, :credit_pool_exhausted, float()}
  def pool_check(provider) do
    pools =
      case GiTF.Config.Provider.get([:costs, :credit_pools]) do
        map when is_map(map) -> Map.new(map, fn {k, v} -> {to_string(k), v} end)
        _ -> %{}
      end

    with %{} = pool <- Map.get(pools, provider),
         pool_usd when is_number(pool_usd) and pool_usd > 0 <-
           pool["pool_usd"] || pool[:pool_usd] do
      spent = spent_since(provider, pool["since"] || pool[:since])

      if spent < pool_usd do
        {:ok, Float.round(pool_usd - spent, 6)}
      else
        {:error, :credit_pool_exhausted, spent}
      end
    else
      # No pool configured for this provider — effectively infinite pool,
      # the daily cap is the only ceiling.
      _ -> {:ok, 1.0e12}
    end
  end

  # Cumulative provider spend since an anchor date (all bookings when nil).
  defp spent_since(provider, anchor) do
    cutoff = parse_anchor(anchor)

    GiTF.Archive.all(:costs)
    |> Enum.filter(fn cost ->
      after_anchor =
        case {cutoff, Map.get(cost, :recorded_at)} do
          {nil, _} -> true
          {%DateTime{} = c, %DateTime{} = ts} -> DateTime.compare(ts, c) != :lt
          # Untimestamped booking with an anchor set: count it (fail-safe).
          _ -> true
        end

      after_anchor and provider_of(cost) == provider
    end)
    |> GiTF.Costs.total()
  end

  defp parse_anchor(%DateTime{} = dt), do: dt

  defp parse_anchor(anchor) when is_binary(anchor) do
    case DateTime.from_iso8601(anchor <> "T00:00:00Z") do
      {:ok, dt, _} ->
        dt

      _ ->
        case DateTime.from_iso8601(anchor) do
          {:ok, dt, _} -> dt
          _ -> nil
        end
    end
  end

  defp parse_anchor(_), do: nil

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
