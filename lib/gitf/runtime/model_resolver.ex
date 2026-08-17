defmodule GiTF.Runtime.ModelResolver do
  @moduledoc """
  Centralized model name resolution.

  Maps tier names ("thinking", "general", "fast") to provider-specific model
  specs (e.g. "google:gemini-2.5-pro", "anthropic:claude-sonnet-4-6").

  The active provider is set via `[llm] provider` in config.toml (default: "google").
  Provider-qualified names like "anthropic:claude-opus-4-6" pass through unchanged.

  ## Tiers

    * `"thinking"` — most capable model, for complex reasoning (design, review)
    * `"general"`  — balanced model for standard work (implementation)
    * `"fast"`     — cheapest model for simple tasks (research, summaries)

  Legacy names ("opus", "sonnet", "haiku") are aliased to the new tiers.

  ## Execution Mode

  Returns `:api`, `:cli`, or `:ollama` based on (in priority order):
  1. `GITF_EXECUTION_MODE` env var
  2. GiTF config `execution_mode`
  3. Application config `:gitf, :llm, :execution_mode`
  4. Default: `:api`
  """

  # Provider-specific model catalogs: tier → model ID
  @provider_models %{
    "google" => %{
      "thinking" => "google:gemini-2.5-pro",
      "general" => "google:gemini-2.5-flash",
      "fast" => "google:gemini-2.5-flash"
    },
    "anthropic" => %{
      "thinking" => "anthropic:claude-opus-4-6",
      "general" => "anthropic:claude-sonnet-4-6",
      "fast" => "anthropic:claude-haiku-4-5"
    }
  }

  # Legacy tier aliases → canonical tier name
  @tier_aliases %{
    "opus" => "thinking",
    "sonnet" => "general",
    "haiku" => "fast",
    # Legacy Claude names → resolve via anthropic provider
    "claude-opus" => "anthropic:claude-opus-4-6",
    "claude-sonnet" => "anthropic:claude-sonnet-4-6",
    "claude-haiku" => "anthropic:claude-haiku-4-5",
    "claude-opus-4-6" => "anthropic:claude-opus-4-6",
    "claude-sonnet-4-6" => "anthropic:claude-sonnet-4-6",
    "claude-haiku-4-5" => "anthropic:claude-haiku-4-5"
  }

  # -- Public API --------------------------------------------------------------

  @doc """
  Resolves a model tier name or qualified name to a provider:model spec.

  - `"thinking"` → provider's thinking model (e.g. `"google:gemini-2.5-pro"`)
  - `"general"` → provider's general model
  - `"fast"` → provider's fast model
  - `"opus"` / `"sonnet"` / `"haiku"` → legacy aliases for the above
  - `"anthropic:claude-opus-4-6"` → passthrough (provider-qualified)
  """
  @spec resolve(String.t()) :: String.t()
  def resolve(name) when is_binary(name) do
    # Provider-qualified names pass through unchanged
    if String.contains?(name, ":") do
      name
    else
      models = configured_models()
      Map.get(models, name, name)
    end
  end

  @doc """
  Returns the configured LLM provider name (e.g. "google", "anthropic").

  Read from `[llm] provider` in config.toml. Defaults to "google".
  """
  @spec configured_provider() :: String.t()
  def configured_provider do
    case GiTF.Runtime.ProviderManager.provider_priority() do
      [first | _] -> first
      _ -> GiTF.Config.Provider.get([:llm, :provider]) || "google"
    end
  rescue
    _ -> "google"
  end

  @doc """
  Normalizes a model name into a short key for comparison and lookups.

  Strips provider prefix, "claude-" version prefix, and any version suffix.
  Used by Trust, Clearance, and intelligence modules to group model variants.

      iex> ModelResolver.normalize_key("anthropic:claude-sonnet-4-6")
      "sonnet"

      iex> ModelResolver.normalize_key("google:gemini-2.5-pro")
      "gemini"

      iex> ModelResolver.normalize_key(nil)
      nil
  """
  @spec normalize_key(String.t() | atom() | nil) :: String.t() | nil
  def normalize_key(nil), do: nil

  def normalize_key(model) when is_binary(model) do
    # parts: 2 — bedrock IDs carry a trailing version colon
    # ("...claude-sonnet-4-6...-v1:0") and ollama uses ":tag"; List.last
    # of a full split collapsed every such model into a bucket named "0"
    # (or "32b"), destroying per-model trust/performance data. ARNs keep
    # only their final path segment.
    model
    |> String.split(":", parts: 2)
    |> List.last()
    |> String.split("/")
    |> List.last()
    |> String.replace(~r/:\d+$/, "")
    |> String.replace("anthropic.", "")
    |> String.replace("claude-", "")
    |> String.split("-")
    |> hd()
  end

  def normalize_key(model) when is_atom(model), do: normalize_key(Atom.to_string(model))

  @doc "Returns the ordered provider priority list."
  def provider_priority do
    GiTF.Runtime.ProviderManager.provider_priority()
  rescue
    _ -> [configured_provider()]
  end

  @doc """
  Returns the current execution mode: `:api`, `:cli`, `:ollama`, or `:bedrock`.

  Checked in priority order:
  1. `GITF_EXECUTION_MODE` env var
  2. GiTF config file `execution_mode`
  3. Application config `:gitf, :llm, :execution_mode`
  4. Default: `:api`
  """
  @spec execution_mode() :: :api | :cli | :ollama | :bedrock
  def execution_mode do
    case System.get_env("GITF_EXECUTION_MODE") do
      "api" -> :api
      "cli" -> :cli
      "ollama" -> :ollama
      "bedrock" -> :bedrock
      _ -> hive_config_mode() || app_config_mode() || :api
    end
  end

  @doc """
  Returns true if the current execution mode uses API calls
  (`:api`, `:ollama`, or `:bedrock`).
  """
  @spec api_mode?() :: boolean()
  def api_mode? do
    execution_mode() in [:api, :ollama, :bedrock]
  end

  @doc """
  Returns true if the current execution mode is `:ollama`.
  """
  @spec ollama_mode?() :: boolean()
  def ollama_mode? do
    execution_mode() == :ollama
  end

  @doc """
  Returns true if the current execution mode is `:bedrock`.
  """
  @spec bedrock_mode?() :: boolean()
  def bedrock_mode? do
    execution_mode() == :bedrock
  end

  @doc """
  Sets up the environment for Ollama mode.

  Auto-configures `OPENAI_API_BASE` to point at a local Ollama instance
  if not already set. Called during application startup when execution
  mode is `:ollama`.
  """
  @spec setup_ollama_env() :: :ok
  def setup_ollama_env do
    base = System.get_env("OPENAI_API_BASE") || System.get_env("OLLAMA_BASE_URL")

    if base == nil do
      System.put_env("OPENAI_API_BASE", "http://localhost:11434/v1")
    end

    # Ollama doesn't need a real key but ReqLLM may require one to be set
    if System.get_env("OPENAI_API_KEY") == nil do
      System.put_env("OPENAI_API_KEY", "ollama")
    end

    :ok
  end

  @doc """
  Returns the configured default models map.

  In `:ollama` or `:bedrock` mode, overlays mode-specific model defaults
  before applying any user customizations.
  """
  @spec configured_models() :: map()
  def configured_models do
    mode = execution_mode()

    base =
      cond do
        mode == :ollama -> provider_tier_map("ollama") |> Map.merge(mode_defaults(:ollama))
        mode == :bedrock -> provider_tier_map("bedrock") |> Map.merge(mode_defaults(:bedrock))
        mode == :cli -> provider_tier_map("cli") |> Map.merge(mode_defaults(:cli))
        true -> provider_tier_map(configured_provider())
      end

    # Add legacy aliases that resolve to canonical tier specs
    with_aliases = Map.merge(base, resolve_aliases(base))

    # The compile-time :llm default_models is the API-mode starter catalog
    # (google). It must never override the mode-specific maps: merging it
    # last sent bedrock-mode "fast"/alias tiers to google:gemini-2.5-flash
    # on a box with no google key — every fix-op retry died on a dead
    # provider (msn-bf61a1). CLI mode has the same failure shape: the claude
    # CLI rejects provider-qualified specs outright. API mode only.
    if mode == :api do
      Map.merge(with_aliases, app_env_default_models())
    else
      with_aliases
    end
  end

  defp app_env_default_models do
    case Application.get_env(:gitf, :llm) do
      nil -> %{}
      config -> Map.new(config[:default_models] || %{}, fn {k, v} -> {to_string(k), v} end)
    end
  end

  # Build the tier→model map for a given provider (merges config overrides)
  defp provider_tier_map(provider_name) do
    defaults = Map.get(@provider_models, provider_name, @provider_models["google"])

    try do
      case GiTF.Runtime.ProviderManager.tier_models(provider_name) do
        %{thinking: t, general: g, fast: f} when t != "" ->
          %{"thinking" => t, "general" => g, "fast" => f}

        _ ->
          defaults
      end
    rescue
      _ -> defaults
    end
  end

  # Resolve legacy aliases using the current tier map
  defp resolve_aliases(tier_map) do
    @tier_aliases
    |> Enum.map(fn {alias_name, target} ->
      if String.contains?(target, ":") do
        # Direct provider-qualified reference (e.g. "claude-opus" → "anthropic:claude-opus-4-6")
        {alias_name, target}
      else
        # Tier alias (e.g. "opus" → "thinking") — look up in current tier map
        {alias_name, Map.get(tier_map, target, target)}
      end
    end)
    |> Map.new()
  end

  @ollama_defaults %{
    "thinking" => "ollama:qwen2.5-coder:32b",
    "general" => "ollama:qwen2.5-coder:14b",
    "fast" => "ollama:qwen2.5-coder:7b"
  }

  @bedrock_defaults %{
    "thinking" => "amazon_bedrock:anthropic.claude-sonnet-4-6-20250514-v1:0",
    "general" => "amazon_bedrock:anthropic.claude-sonnet-4-6-20250514-v1:0",
    "fast" => "amazon_bedrock:anthropic.claude-haiku-4-5-20251001-v1:0"
  }

  defp mode_defaults(:ollama) do
    case GiTF.Config.Provider.get([:llm, :ollama_models]) do
      nil ->
        @ollama_defaults

      custom when is_map(custom) ->
        Map.merge(@ollama_defaults, Map.new(custom, fn {k, v} -> {to_string(k), v} end))

      _ ->
        @ollama_defaults
    end
  rescue
    _ -> @ollama_defaults
  end

  defp mode_defaults(:bedrock) do
    case GiTF.Config.Provider.get([:llm, :bedrock_models]) do
      nil ->
        @bedrock_defaults

      custom when is_map(custom) ->
        Map.merge(@bedrock_defaults, Map.new(custom, fn {k, v} -> {to_string(k), v} end))

      _ ->
        @bedrock_defaults
    end
  rescue
    _ -> @bedrock_defaults
  end

  # Bare aliases, not full model IDs: the claude CLI resolves "sonnet"/"haiku"
  # to the newest models available to the account, so these never go stale and
  # never carry a provider prefix the CLI would reject.
  @cli_defaults %{
    "thinking" => "sonnet",
    "general" => "sonnet",
    "fast" => "haiku"
  }

  defp mode_defaults(:cli) do
    case GiTF.Config.Provider.get([:llm, :cli_models]) do
      nil ->
        @cli_defaults

      custom when is_map(custom) ->
        Map.merge(@cli_defaults, Map.new(custom, fn {k, v} -> {to_string(k), v} end))

      _ ->
        @cli_defaults
    end
  rescue
    _ -> @cli_defaults
  end

  @doc """
  Returns a fallback model for the given model spec.

  Degrades gracefully: opus → sonnet → haiku. Returns nil if no fallback.
  Used when the primary model fails (API down, billing limit, etc.).
  """
  @spec fallback(String.t()) :: String.t() | nil
  def fallback(model_spec) do
    resolved = resolve(model_spec)
    current_provider = provider(resolved)
    tier = reverse_lookup_tier(resolved) || "general"

    strategy = GiTF.Runtime.ProviderManager.fallback_strategy()

    case strategy do
      "tier_downgrade_first" ->
        tier_fallback(tier, current_provider) || next_provider_model(tier, current_provider)

      _ ->
        # priority_chain: try next provider at same tier first
        next_provider_model(tier, current_provider) || tier_fallback(tier, current_provider)
    end
  end

  defp tier_fallback(tier, current_provider) do
    next_tier =
      case tier do
        t when t in ["thinking", "opus"] -> "general"
        t when t in ["general", "sonnet"] -> "fast"
        _ -> nil
      end

    if next_tier do
      models = GiTF.Runtime.ProviderManager.tier_models(current_provider)

      # tier_models coerces unknown providers/tiers to "" — an empty spec is
      # truthy, so without this guard it wins the || chain in fallback/1 and
      # the ghost respawns with model "" (:invalid_format masking the real
      # upstream failure).
      case Map.get(models, String.to_atom(next_tier)) do
        model when is_binary(model) and model != "" -> model
        _ -> nil
      end
    end
  end

  defp next_provider_model(tier, current_provider) do
    priority = provider_priority()
    current_idx = Enum.find_index(priority, &(&1 == current_provider))

    priority
    |> Enum.drop((current_idx || 0) + 1)
    |> Enum.find_value(fn next ->
      if GiTF.Runtime.ProviderManager.provider_enabled?(next) do
        models = GiTF.Runtime.ProviderManager.tier_models(next)
        model = Map.get(models, String.to_atom(tier)) || Map.get(models, :general)
        if model && model != "", do: model
      end
    end)
  end

  @doc """
  Returns a more capable model for the given model spec.

  Escalates: fast → general → thinking. Returns nil if already at thinking.
  Used when retrying failed ops with a stronger model.

  Skips tiers that resolve to the same model spec as the input — some
  configs collapse fast and general onto the same provider model
  (e.g. google maps both to gemini-2.5-flash); without skipping, the
  "escalation" would return the same broken model.
  """
  @spec escalate(String.t()) :: String.t() | nil
  def escalate(model_spec) do
    resolved = resolve(model_spec)
    tier = reverse_lookup_tier(resolved)

    next =
      case tier do
        t when t in ["fast", "haiku"] -> resolve("general")
        t when t in ["general", "sonnet"] -> resolve("thinking")
        _ -> nil
      end

    cond do
      is_nil(next) ->
        nil

      next == resolved ->
        # Tier collision: next tier maps to the same model. Jump again.
        case tier do
          t when t in ["fast", "haiku"] -> resolve("thinking")
          _ -> nil
        end

      true ->
        next
    end
  end

  # Reverse lookup: resolved model spec → tier name
  defp reverse_lookup_tier(resolved) do
    configured_models()
    |> Enum.find_value(fn {tier_name, spec} ->
      if spec == resolved, do: tier_name
    end)
  end

  @doc """
  Returns the provider name from a model spec string.

  ## Examples

      iex> ModelResolver.provider("anthropic:claude-opus-4-6")
      "anthropic"

      iex> ModelResolver.provider("claude-sonnet")
      "anthropic"
  """
  @spec provider(String.t()) :: String.t()
  def provider(model_spec) do
    resolved = resolve(model_spec)

    # Normalize to the @known_providers/tier_models key space (same mapping
    # as ProviderCircuit.extract_provider/1): bedrock specs appear as ARNs
    # or "amazon_bedrock:" prefixes, but the provider tables key "bedrock" —
    # an unnormalized name makes tier_models return empty strings and every
    # fallback resolve to "".
    cond do
      String.starts_with?(resolved, "arn:aws:bedrock:") ->
        "bedrock"

      true ->
        case String.split(resolved, ":", parts: 2) do
          ["amazon_bedrock", _model] -> "bedrock"
          [provider, _model] -> provider
          _ -> "google"
        end
    end
  end

  @doc """
  Returns the model ID (without provider prefix) from a model spec.

  ## Examples

      iex> ModelResolver.model_id("anthropic:claude-opus-4-6")
      "claude-opus-4-6"

      iex> ModelResolver.model_id("claude-sonnet")
      "claude-sonnet-4-6"
  """
  @spec model_id(String.t()) :: String.t()
  def model_id(model_spec) do
    resolved = resolve(model_spec)

    case String.split(resolved, ":", parts: 2) do
      [_provider, model] -> model
      _ -> resolved
    end
  end

  # -- Private -----------------------------------------------------------------

  defp hive_config_mode do
    mode =
      GiTF.Config.Provider.get([:llm, :execution_mode]) ||
        GiTF.Config.Provider.get([:execution_mode])

    parse_mode(mode)
  rescue
    _ -> nil
  end

  defp app_config_mode do
    get_in(Application.get_env(:gitf, :llm, []), [:execution_mode])
    |> parse_mode()
  end

  defp parse_mode("api"), do: :api
  defp parse_mode(:api), do: :api
  defp parse_mode("cli"), do: :cli
  defp parse_mode(:cli), do: :cli
  defp parse_mode("ollama"), do: :ollama
  defp parse_mode(:ollama), do: :ollama
  defp parse_mode("bedrock"), do: :bedrock
  defp parse_mode(:bedrock), do: :bedrock
  defp parse_mode(_), do: nil
end
