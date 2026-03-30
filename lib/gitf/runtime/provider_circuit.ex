defmodule GiTF.Runtime.ProviderCircuit do
  @moduledoc """
  Per-provider circuit breaker for LLM API calls.

  Wraps every LLM call with a provider-specific circuit breaker (keyed as
  `"llm:<provider>"`). When a provider's circuit is open, automatically
  finds a fallback model from the next available provider in the priority
  chain — so a Google 429 transparently routes to Bedrock without the
  ghost ever noticing.

  ## Circuit Keys

      "llm:google"     — Google / Gemini API
      "llm:bedrock"    — AWS Bedrock
      "llm:anthropic"  — Anthropic direct API
      "llm:openai"     — OpenAI API
      ...

  ## Probe Intervals

  Each provider has a configurable probe interval — the minimum time
  between Tachikoma recovery probes. This prevents hammering a provider
  that may take hours to recover (e.g., Google spending cap) while still
  checking cheap/fast providers frequently.

      google     — 10 min  (spending caps can take hours to reset)
      anthropic  — 3 min   (rate limits usually clear quickly)
      bedrock    — 2 min   (AWS rarely has sustained outages)
      openai     — 3 min
      ollama     — 1 min   (local, cheap to probe)
      default    — 5 min

  Override via config: `[llm.providers.<name>] probe_interval_s = 120`

  ## Fallback Strategy

  When a circuit is open, `find_available_model/1` walks the provider
  priority list to find the next enabled provider whose circuit is closed
  (or half-open). It preserves the requested tier (thinking/general/fast)
  when possible.

  The Tachikoma background probe periodically tests providers with open
  circuits and resets them when they recover.
  """

  require Logger

  alias GiTF.CircuitBreaker
  alias GiTF.Runtime.{ModelResolver, ProviderManager}

  @circuit_prefix "llm:"

  # Probe intervals by failure mode (seconds).
  # Determines how long Tachikoma waits between recovery probes based on
  # WHY the circuit opened — not just which provider it was.
  @failure_mode_intervals %{
    quota_exhausted: 1800,   # 30 min — spending caps / billing limits, may take hours
    billing_error: 1800,     # 30 min — payment issues, needs manual intervention
    rate_limited: 120,       # 2 min  — transient throttle, clears quickly
    auth_error: 900,         # 15 min — bad key / expired creds, needs manual fix
    server_error: 180,       # 3 min  — 500/502/503, usually brief
    connection_error: 60,    # 1 min  — network blip, often instant recovery
    model_not_found: 3600,   # 60 min — misconfigured model, needs manual fix
    unknown: 300             # 5 min  — safe default
  }

  # Provider-specific base intervals (seconds) used as a floor.
  # The actual interval is max(failure_mode_interval, provider_base).
  @provider_base_intervals %{
    "ollama" => 30,       # local, zero cost
    "bedrock" => 60,      # AWS is reliable
    "anthropic" => 60,
    "openai" => 60,
    "google" => 120,      # Google quotas are sticky
    "groq" => 60,
    "mistral" => 60,
    "together" => 60,
    "fireworks" => 60
  }
  @default_provider_base 60

  # -- Public API --------------------------------------------------------------

  @doc """
  Executes an LLM call through the provider's circuit breaker.

  If the provider's circuit is open, attempts to reroute to a fallback
  provider. Returns `{:ok, response}`, `{:error, reason}`, or
  `{:error, :all_providers_unavailable}`.

  The `call_fn` receives the (possibly rerouted) model and must return
  `{:ok, response}` or `{:error, reason}`.
  """
  @spec call(String.t(), (String.t() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def call(model, call_fn) do
    provider = extract_provider(model)
    circuit_key = @circuit_prefix <> provider

    case CircuitBreaker.get_state(circuit_key) do
      :open ->
        maybe_broadcast_open(provider)

        case find_available_model(model) do
          {:ok, fallback_model, fallback_provider} ->
            Logger.info(
              "Provider circuit open for #{provider}, rerouting to #{fallback_provider}: #{short_model(fallback_model)}"
            )

            fallback_key = @circuit_prefix <> fallback_provider

            CircuitBreaker.call_with_retry(fallback_key, fn ->
              call_fn.(fallback_model)
            end, max_retries: 2)

          :none ->
            Logger.warning("All provider circuits unavailable, attempting probe on #{provider}")
            CircuitBreaker.call_with_retry(circuit_key, fn -> call_fn.(model) end, max_retries: 2)
        end

      _closed_or_half_open ->
        CircuitBreaker.call_with_retry(circuit_key, fn -> call_fn.(model) end, max_retries: 2)
    end
  end

  @doc """
  Returns the circuit breaker key for a provider name.
  """
  @spec circuit_key(String.t()) :: String.t()
  def circuit_key(provider), do: @circuit_prefix <> provider

  @doc """
  Returns the circuit prefix used for all LLM provider circuits.
  """
  @spec prefix() :: String.t()
  def prefix, do: @circuit_prefix

  @doc """
  Returns the state of a provider's circuit breaker.
  """
  @spec provider_state(String.t()) :: :closed | :open | :half_open
  def provider_state(provider) do
    CircuitBreaker.get_state(@circuit_prefix <> provider)
  end

  @doc """
  Lists all providers with open circuits.
  """
  @spec open_providers() :: [String.t()]
  def open_providers do
    CircuitBreaker.list_open(@circuit_prefix)
    |> Enum.map(fn key -> String.replace_prefix(key, @circuit_prefix, "") end)
  end

  @doc """
  Resets a provider's circuit breaker to closed.
  """
  @spec reset_provider(String.t()) :: :ok
  def reset_provider(provider) do
    CircuitBreaker.reset(@circuit_prefix <> provider)
    CircuitBreaker.clear_metadata(@circuit_prefix <> provider, :open_broadcast)
    clear_last_probe(provider)
  end

  @doc """
  Returns the probe interval (in seconds) for a provider.

  The interval depends on the failure mode that opened the circuit:
  - `:quota_exhausted` / `:billing_error` → 30 min (needs billing reset)
  - `:rate_limited` → 2 min (clears quickly)
  - `:auth_error` → 15 min (needs manual fix)
  - `:server_error` → 3 min (usually brief)
  - `:connection_error` → 1 min (network blips)
  - `:model_not_found` → 60 min (misconfigured)

  Config override: `[llm.providers.<name>] probe_interval_s = 120`
  """
  @spec probe_interval(String.t()) :: pos_integer()
  def probe_interval(provider) do
    case get_config_probe_interval(provider) do
      n when is_integer(n) and n > 0 ->
        n

      _ ->
        failure_mode = classify_failure(provider)
        mode_interval = Map.get(@failure_mode_intervals, failure_mode, @failure_mode_intervals.unknown)
        provider_base = Map.get(@provider_base_intervals, provider, @default_provider_base)
        max(mode_interval, provider_base)
    end
  end

  @doc """
  Returns the classified failure mode for a provider's open circuit.
  """
  @spec failure_mode(String.t()) :: atom()
  def failure_mode(provider) do
    classify_failure(provider)
  end

  @doc """
  Returns true if enough time has elapsed since the last probe for this provider.

  The Tachikoma should call this before testing a provider to avoid hammering
  providers that take a long time to recover.
  """
  @spec probe_due?(String.t()) :: boolean()
  def probe_due?(provider) do
    interval_ms = probe_interval(provider) * 1_000

    case get_last_probe(provider) do
      nil -> true
      last_ms -> System.monotonic_time(:millisecond) - last_ms >= interval_ms
    end
  end

  @doc """
  Records that a probe was just attempted for this provider.
  """
  @spec record_probe(String.t()) :: :ok
  def record_probe(provider) do
    CircuitBreaker.put_metadata(@circuit_prefix <> provider, :last_probe, System.monotonic_time(:millisecond))
  end

  @doc """
  Returns the estimated seconds until the next probe for an open provider circuit.

  Returns `0` if the probe is due now, or `nil` if the circuit is not open.
  """
  @spec seconds_until_probe(String.t()) :: non_neg_integer() | nil
  def seconds_until_probe(provider) do
    if provider_state(provider) != :open, do: nil, else: do_seconds_until_probe(provider)
  end

  defp do_seconds_until_probe(provider) do
    interval_s = probe_interval(provider)

    case get_last_probe(provider) do
      nil -> 0
      last_ms ->
        elapsed_ms = System.monotonic_time(:millisecond) - last_ms
        max(0, interval_s - div(elapsed_ms, 1000))
    end
  end

  # -- Private: Fallback Logic -------------------------------------------------

  @doc """
  Finds an available model from another provider when the current one is down.

  Walks the provider priority list, skipping providers with open circuits
  or that are disabled. Preserves the requested tier when possible.

  Returns `{:ok, model, provider}` or `:none`.
  """
  @spec find_available_model(String.t()) :: {:ok, String.t(), String.t()} | :none
  def find_available_model(model) do
    current_provider = extract_provider(model)
    tier = infer_tier(model, current_provider)

    # Build candidate list: priority providers first, then any others with keys
    priority = ProviderManager.provider_priority()
    all_known = Map.keys(ProviderManager.known_providers())
    extras = Enum.filter(all_known -- priority, &ProviderManager.api_key_for/1)
    candidates = (priority ++ extras) |> Enum.reject(&(&1 == current_provider))

    result =
      Enum.find_value(candidates, fn candidate ->
        candidate_key = @circuit_prefix <> candidate

        if ProviderManager.provider_enabled?(candidate) and
             CircuitBreaker.get_state(candidate_key) != :open do
          models = ProviderManager.tier_models(candidate)
          candidate_model = Map.get(models, tier) || Map.get(models, :general)

          if candidate_model && candidate_model != "" do
            {:ok, candidate_model, candidate}
          end
        end
      end)

    result || :none
  end

  # -- Private: Helpers --------------------------------------------------------

  defp extract_provider(model) when is_binary(model) do
    cond do
      String.starts_with?(model, "arn:aws:bedrock:") -> "bedrock"
      String.contains?(model, ":") ->
        case String.split(model, ":", parts: 2) do
          ["amazon_bedrock", _] -> "bedrock"
          [provider, _] -> provider
          _ -> ModelResolver.configured_provider()
        end
      true ->
        ModelResolver.configured_provider()
    end
  end

  defp extract_provider(_model), do: ModelResolver.configured_provider()

  defp infer_tier(model, provider) do
    models = ProviderManager.tier_models(provider)

    Enum.find_value([:thinking, :general, :fast], :general, fn tier ->
      if Map.get(models, tier) == model, do: tier
    end)
  end

  # Broadcast once when we first detect a circuit is open.
  # Uses :open_broadcast metadata to avoid spamming on every call.
  defp maybe_broadcast_open(provider) do
    key = @circuit_prefix <> provider

    unless CircuitBreaker.get_metadata(key, :open_broadcast) do
      CircuitBreaker.put_metadata(key, :open_broadcast, true)
      failure_mode = classify_failure(provider)

      Phoenix.PubSub.broadcast(
        GiTF.PubSub,
        "provider:circuit",
        {:circuit_opened, provider, failure_mode}
      )
    end
  rescue
    _ -> :ok
  end

  defp short_model(model) do
    if String.length(model) > 60 do
      String.slice(model, 0, 57) <> "..."
    else
      model
    end
  end

  # Classify the failure reason stored in the circuit breaker into a mode
  # that determines how aggressively we should re-probe.
  defp classify_failure(provider) do
    reason = CircuitBreaker.last_failure_reason(@circuit_prefix <> provider)
    classify_reason(reason)
  end

  @doc false
  def classify_reason(nil), do: :unknown

  def classify_reason(reason) when is_binary(reason) do
    lower = String.downcase(reason)

    cond do
      # Quota / spending cap — takes hours to reset
      String.contains?(lower, "spending cap") -> :quota_exhausted
      String.contains?(lower, "quota") -> :quota_exhausted
      String.contains?(lower, "resource_exhausted") -> :quota_exhausted
      String.contains?(lower, "billing") -> :billing_error
      String.contains?(lower, "payment") -> :billing_error

      # Rate limiting — transient, clears in seconds/minutes
      String.contains?(lower, "rate limit") -> :rate_limited
      String.contains?(lower, "too many requests") -> :rate_limited
      String.contains?(lower, "throttl") -> :rate_limited
      # Bare 429 without spending/quota keywords = rate limit
      String.contains?(lower, "429") -> :rate_limited

      # Auth errors — needs manual credential fix
      String.contains?(lower, "401") -> :auth_error
      String.contains?(lower, "403") -> :auth_error
      String.contains?(lower, "unauthorized") -> :auth_error
      String.contains?(lower, "forbidden") -> :auth_error
      String.contains?(lower, "invalid") and String.contains?(lower, "key") -> :auth_error
      String.contains?(lower, "expired") -> :auth_error

      # Model / config errors — needs manual fix
      String.contains?(lower, "not_found") -> :model_not_found
      String.contains?(lower, "unknown provider") -> :model_not_found
      String.contains?(lower, "unsupported model") -> :model_not_found
      String.contains?(lower, "404") -> :model_not_found

      # Server errors — usually brief
      String.contains?(lower, "500") -> :server_error
      String.contains?(lower, "502") -> :server_error
      String.contains?(lower, "503") -> :server_error
      String.contains?(lower, "529") -> :server_error
      String.contains?(lower, "overloaded") -> :server_error
      String.contains?(lower, "internal server") -> :server_error

      # Connection errors — often instant recovery
      String.contains?(lower, "timeout") -> :connection_error
      String.contains?(lower, "econnrefused") -> :connection_error
      String.contains?(lower, "connection") -> :connection_error
      String.contains?(lower, "closed") -> :connection_error

      true -> :unknown
    end
  end

  def classify_reason(%{status: status}) when status in [401, 403], do: :auth_error
  def classify_reason(%{status: 429, body: body}) when is_map(body) do
    text = inspect(body) |> String.downcase()
    if String.contains?(text, "spending") or String.contains?(text, "quota"),
      do: :quota_exhausted,
      else: :rate_limited
  end
  def classify_reason(%{status: 429}), do: :rate_limited
  def classify_reason(%{status: s}) when s in [500, 502, 503, 529], do: :server_error
  def classify_reason(%{status: 404}), do: :model_not_found
  def classify_reason(:rate_limited), do: :rate_limited
  def classify_reason(:timeout), do: :connection_error
  def classify_reason(:econnrefused), do: :connection_error
  def classify_reason(:closed), do: :connection_error
  def classify_reason({:api_error, inner}), do: classify_reason(inner)
  def classify_reason(_), do: :unknown

  defp get_last_probe(provider) do
    CircuitBreaker.get_metadata(@circuit_prefix <> provider, :last_probe)
  end

  defp clear_last_probe(provider) do
    CircuitBreaker.clear_metadata(@circuit_prefix <> provider, :last_probe)
  end

  defp get_config_probe_interval(provider) do
    GiTF.Config.Provider.get([:llm, :providers, String.to_atom(provider), :probe_interval_s]) ||
      GiTF.Config.Provider.get([:llm, :providers, provider, :probe_interval_s])
  rescue
    _ -> nil
  end
end
