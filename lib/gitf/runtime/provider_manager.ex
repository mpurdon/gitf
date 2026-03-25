defmodule GiTF.Runtime.ProviderManager do
  @moduledoc "Manages LLM provider configuration, priority ordering, and fallback strategy."

  alias GiTF.Config.Provider, as: Config

  @known_providers %{
    "google" => %{
      color: "#58a6ff", glyph: "G", auth: :api_key,
      thinking: "google:gemini-2.5-pro",
      general: "google:gemini-2.5-flash",
      fast: "google:gemini-2.5-flash"
    },
    "anthropic" => %{
      color: "#f07070", glyph: "A", auth: :api_key,
      thinking: "anthropic:claude-opus-4-6",
      general: "anthropic:claude-sonnet-4-6",
      fast: "anthropic:claude-haiku-4-5"
    },
    "bedrock" => %{
      color: "#f0983e", glyph: "B", auth: :aws_profile,
      thinking: "bedrock:anthropic.claude-sonnet-4-6-20250514-v1:0",
      general: "bedrock:anthropic.claude-sonnet-4-6-20250514-v1:0",
      fast: "bedrock:anthropic.claude-haiku-4-5-20251001-v1:0"
    },
    "openai" => %{
      color: "#3fb950", glyph: "O", auth: :api_key,
      thinking: "openai:gpt-4o",
      general: "openai:gpt-4o",
      fast: "openai:gpt-4o-mini"
    },
    "ollama" => %{
      color: "#3fb950", glyph: "L", auth: :none,
      thinking: "openai:qwen2.5-coder:32b",
      general: "openai:qwen2.5-coder:14b",
      fast: "openai:qwen2.5-coder:7b"
    },
    "groq" => %{color: "#8b949e", glyph: "Q", auth: :api_key, thinking: "groq:llama3-70b", general: "groq:llama3-70b", fast: "groq:llama3-8b"},
    "mistral" => %{color: "#8b949e", glyph: "M", auth: :api_key, thinking: "mistral:mistral-large", general: "mistral:mistral-medium", fast: "mistral:mistral-small"},
    "together" => %{color: "#8b949e", glyph: "T", auth: :api_key, thinking: "together:meta-llama/Llama-3-70b", general: "together:meta-llama/Llama-3-70b", fast: "together:meta-llama/Llama-3-8b"},
    "fireworks" => %{color: "#8b949e", glyph: "F", auth: :api_key, thinking: "fireworks:llama-v3-70b", general: "fireworks:llama-v3-70b", fast: "fireworks:llama-v3-8b"}
  }

  @key_env_map %{
    "google" => "GOOGLE_API_KEY",
    "anthropic" => "ANTHROPIC_API_KEY",
    "openai" => "OPENAI_API_KEY",
    "groq" => "GROQ_API_KEY",
    "mistral" => "MISTRAL_API_KEY",
    "together" => "TOGETHER_API_KEY",
    "fireworks" => "FIREWORKS_API_KEY"
  }

  # -- Read ------------------------------------------------------------------

  def known_providers, do: @known_providers

  @doc "Returns all providers: configured ones in priority order, then unconfigured."
  def list_providers do
    priority = provider_priority()
    configured = Enum.map(priority, &build_provider_info/1)
    unconfigured_names = Map.keys(@known_providers) -- priority

    unconfigured =
      unconfigured_names
      |> Enum.sort()
      |> Enum.map(&build_provider_info/1)

    {configured, unconfigured}
  end

  @doc "Returns the ordered provider priority list."
  def provider_priority do
    case Config.get([:llm, :provider_priority]) do
      list when is_list(list) and list != [] ->
        Enum.map(list, &to_string/1)

      _ ->
        provider = Config.get([:llm, :provider]) || "google"
        [to_string(provider)]
    end
  end

  @doc "Returns the current fallback strategy."
  def fallback_strategy do
    case Config.get([:llm, :fallback_strategy]) do
      s when s in ["priority_chain", "tier_downgrade_first"] -> s
      _ -> "priority_chain"
    end
  end

  @doc "Returns tier model mapping for a provider, merged with config overrides."
  def tier_models(provider_name) do
    defaults = Map.get(@known_providers, provider_name, %{})
    config_overrides = get_provider_config(provider_name)

    %{
      thinking: to_string(config_overrides[:thinking] || defaults[:thinking] || ""),
      general: to_string(config_overrides[:general] || defaults[:general] || ""),
      fast: to_string(config_overrides[:fast] || defaults[:fast] || "")
    }
  end

  @doc "Returns provider status: :connected, :configured, or :unconfigured."
  def provider_status(name) do
    cond do
      name == "bedrock" -> bedrock_status()
      name == "ollama" -> :configured
      has_api_key?(name) -> :configured
      true -> :unconfigured
    end
  end

  @doc "Returns provider info map."
  def provider_info(name), do: build_provider_info(name)

  @doc "Returns whether a provider is enabled."
  def provider_enabled?(name) do
    case get_provider_config(name) do
      %{enabled: false} -> false
      %{"enabled" => false} -> false
      _ -> true
    end
  end

  @doc "Aggregates cost stats for a provider from the archive."
  def provider_stats(name) do
    costs = GiTF.Archive.all(:costs)

    provider_costs = Enum.filter(costs, fn c ->
      model = to_string(c[:model] || "")
      String.starts_with?(model, name <> ":")
    end)

    total = length(provider_costs)
    total_cost = Enum.sum(Enum.map(provider_costs, &(Map.get(&1, :cost_usd, 0.0))))

    %{
      total_calls: total,
      total_cost: total_cost
    }
  rescue
    _ -> %{total_calls: 0, total_cost: 0.0}
  end

  @doc "Tests connection to a provider's fast-tier model. Returns {:ok, latency_ms} or {:error, reason}."
  def test_connection(name) do
    models = tier_models(name)
    model = models[:fast] || models[:general]

    if model == "" do
      {:error, :no_model_configured}
    else
      start = System.monotonic_time(:millisecond)

      case ReqLLM.generate_text(model, [%{role: "user", content: "Say OK"}], max_tokens: 5) do
        {:ok, _response} ->
          latency = System.monotonic_time(:millisecond) - start
          {:ok, latency}

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # -- Write -----------------------------------------------------------------

  @doc "Saves current provider config to config.toml and reloads."
  def save!(priority, strategy, provider_configs) do
    global_path = GiTF.global_config_path()
    existing = GiTF.Config.read_config(global_path)

    llm = Map.get(existing, "llm", %{})

    # Update priority and strategy
    llm = Map.merge(llm, %{
      "provider_priority" => priority,
      "fallback_strategy" => strategy,
      "provider" => List.first(priority) || "google"
    })

    # Update per-provider configs
    providers =
      Enum.reduce(provider_configs, %{}, fn {name, config}, acc ->
        Map.put(acc, name, config)
      end)

    llm = Map.put(llm, "providers", providers)

    # Update API keys
    keys = Map.get(llm, "keys", %{})

    keys =
      Enum.reduce(provider_configs, keys, fn {name, config}, acc ->
        case Map.get(config, "api_key") || Map.get(config, :api_key) do
          key when is_binary(key) and key != "" -> Map.put(acc, name, key)
          _ -> acc
        end
      end)

    # Handle AWS profile for bedrock
    keys =
      case get_in(provider_configs, ["bedrock", "aws_profile"]) ||
           get_in(provider_configs, ["bedrock", :aws_profile]) do
        profile when is_binary(profile) and profile != "" ->
          Map.put(keys, "aws_profile", profile)
        _ -> keys
      end

    llm = Map.put(llm, "keys", keys)
    updated = Map.put(existing, "llm", llm)

    GiTF.Config.write_config(global_path, updated)
    GiTF.Config.Provider.reload()
    GiTF.Runtime.Keys.load()

    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  # -- Private ---------------------------------------------------------------

  defp build_provider_info(name) do
    catalog = Map.get(@known_providers, name, %{})
    config = get_provider_config(name)
    models = tier_models(name)

    %{
      name: name,
      color: catalog[:color] || "#8b949e",
      glyph: catalog[:glyph] || String.first(name) |> String.upcase(),
      auth: catalog[:auth] || :api_key,
      enabled: provider_enabled?(name),
      status: provider_status(name),
      models: models,
      aws_profile: get_aws_profile(config),
      api_key_set: has_api_key?(name)
    }
  end

  defp get_provider_config(name) do
    case Config.get([:llm, :providers, String.to_atom(name)]) do
      config when is_map(config) -> config
      _ ->
        case Config.get([:llm, :providers, name]) do
          config when is_map(config) -> config
          _ -> %{}
        end
    end
  rescue
    _ -> %{}
  end

  defp has_api_key?(name) do
    # Check config keys
    key = Config.get([:llm, :keys, String.to_atom(name)]) ||
          Config.get([:llm, :keys, name])

    if is_binary(key) and key != "" do
      true
    else
      # Check env var
      env_var = Map.get(@key_env_map, name)
      env_var && System.get_env(env_var) != nil
    end
  rescue
    _ -> false
  end

  defp bedrock_status do
    has_profile = (Config.get([:llm, :keys, :aws_profile]) || "") != ""
    has_env = System.get_env("AWS_ACCESS_KEY_ID") != nil

    if has_profile or has_env, do: :configured, else: :unconfigured
  end

  defp get_aws_profile(config) do
    config[:aws_profile] || config["aws_profile"] ||
      Config.get([:llm, :keys, :aws_profile]) || ""
  rescue
    _ -> ""
  end
end
