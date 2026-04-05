defmodule GiTF.Runtime.ProviderManager do
  @moduledoc "Manages LLM provider configuration, priority ordering, and fallback strategy."

  alias GiTF.Config.Provider, as: Config

  @known_providers %{
    "google" => %{
      color: "#58a6ff",
      glyph: "G",
      auth: :api_key,
      thinking: "google:gemini-2.5-pro",
      general: "google:gemini-2.5-flash",
      fast: "google:gemini-2.5-flash"
    },
    "anthropic" => %{
      color: "#f07070",
      glyph: "A",
      auth: :api_key,
      thinking: "anthropic:claude-opus-4-6",
      general: "anthropic:claude-sonnet-4-6",
      fast: "anthropic:claude-haiku-4-5"
    },
    "bedrock" => %{
      color: "#f0983e",
      glyph: "B",
      auth: :aws_profile,
      thinking: "amazon_bedrock:anthropic.claude-sonnet-4-6-20250514-v1:0",
      general: "amazon_bedrock:anthropic.claude-sonnet-4-6-20250514-v1:0",
      fast: "amazon_bedrock:anthropic.claude-haiku-4-5-20251001-v1:0"
    },
    "openai" => %{
      color: "#3fb950",
      glyph: "O",
      auth: :api_key,
      thinking: "openai:gpt-4o",
      general: "openai:gpt-4o",
      fast: "openai:gpt-4o-mini"
    },
    "ollama" => %{
      color: "#3fb950",
      glyph: "L",
      auth: :none,
      thinking: "ollama:qwen2.5-coder:32b",
      general: "ollama:qwen2.5-coder:14b",
      fast: "ollama:qwen2.5-coder:7b"
    },
    "groq" => %{
      color: "#8b949e",
      glyph: "Q",
      auth: :api_key,
      thinking: "groq:llama3-70b",
      general: "groq:llama3-70b",
      fast: "groq:llama3-8b"
    },
    "mistral" => %{
      color: "#8b949e",
      glyph: "M",
      auth: :api_key,
      thinking: "mistral:mistral-large",
      general: "mistral:mistral-medium",
      fast: "mistral:mistral-small"
    },
    "together" => %{
      color: "#8b949e",
      glyph: "T",
      auth: :api_key,
      thinking: "together:meta-llama/Llama-3-70b",
      general: "together:meta-llama/Llama-3-70b",
      fast: "together:meta-llama/Llama-3-8b"
    },
    "fireworks" => %{
      color: "#8b949e",
      glyph: "F",
      auth: :api_key,
      thinking: "fireworks:llama-v3-70b",
      general: "fireworks:llama-v3-70b",
      fast: "fireworks:llama-v3-8b"
    }
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
      thinking:
        to_string(
          config_overrides[:thinking] || config_overrides["thinking"] || defaults[:thinking] || ""
        ),
      general:
        to_string(
          config_overrides[:general] || config_overrides["general"] || defaults[:general] || ""
        ),
      fast:
        to_string(config_overrides[:fast] || config_overrides["fast"] || defaults[:fast] || "")
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

    provider_costs =
      Enum.filter(costs, fn c ->
        model = to_string(c[:model] || "")
        String.starts_with?(model, name <> ":")
      end)

    total = length(provider_costs)
    total_cost = Enum.sum(Enum.map(provider_costs, &Map.get(&1, :cost_usd, 0.0)))

    %{
      total_calls: total,
      total_cost: total_cost
    }
  rescue
    _ -> %{total_calls: 0, total_cost: 0.0}
  end

  @doc """
  Tests a provider connection using the same code path ghosts use.

  Sends "Say OK" via ReqLLM or BedrockDirect (bypassing circuit breaker
  so we test THIS provider, not a fallback) and verifies the response
  has actual content. If the test passes, ghosts will work too.
  """
  def test_connection(name, opts \\ %{}) do
    model = to_string(opts[:fast] || opts[:general] || "")

    model =
      if model == "" do
        models = tier_models(name)
        to_string(models[:fast] || models[:general] || "")
      else
        model
      end

    if model == "" do
      {:error,
       diagnostic("No model configured for #{name}", %{provider: name, step: :resolve_model})}
    else
      # For bedrock, ensure credentials are loaded before testing
      if name == "bedrock" do
        profile = to_string(opts[:aws_profile] || Config.get([:llm, :keys, :aws_profile]) || "")
        region = to_string(opts[:aws_region] || "us-east-1")
        if profile != "", do: GiTF.Runtime.Keys.load_aws_profile(profile)
        if region != "", do: System.put_env("AWS_REGION", region)
      end

      test_via_llm_client(name, model)
    end
  rescue
    e ->
      {:error,
       diagnostic(Exception.message(e), %{
         provider: name,
         step: :setup,
         exception: e.__struct__,
         stacktrace: Exception.format_stacktrace(__STACKTRACE__) |> String.slice(0, 500)
       })}
  end

  defp test_via_llm_client(provider_name, model) do
    start = System.monotonic_time(:millisecond)
    messages = [%{role: "user", content: "Say OK"}]

    # Build diagnostic context
    is_arn = is_binary(model) and String.starts_with?(model, "arn:aws:bedrock:")
    has_key = api_key_for(provider_name) != nil
    has_aws = System.get_env("AWS_ACCESS_KEY_ID") != nil

    diag_base = %{
      provider: provider_name,
      model: model,
      is_arn: is_arn,
      has_api_key: has_key,
      has_aws_creds: has_aws
    }

    # Call the same code path ghosts use, but bypass ProviderCircuit
    # so we test THIS provider specifically (not a fallback).
    opts =
      case api_key_for(provider_name) do
        nil -> [max_tokens: 5]
        key -> [max_tokens: 5, api_key: key]
      end

    opts =
      if provider_name == "ollama" do
        base = System.get_env("OLLAMA_BASE_URL") || "http://localhost:11434"

        opts
        |> Keyword.put(:base_url, base <> "/v1")
        |> Keyword.put_new(:api_key, "ollama")
      else
        opts
      end

    result =
      if is_arn do
        GiTF.Runtime.BedrockDirect.converse(model, messages, opts)
      else
        ReqLLM.generate_text(normalize_model_for_reqllm(model), messages, opts)
      end

    case result do
      {:ok, response} ->
        text = ReqLLM.Response.text(response) || ""
        usage = Map.get(response, :usage, %{})
        latency = System.monotonic_time(:millisecond) - start

        if String.trim(text) != "" do
          {:ok, latency}
        else
          {:error,
           diagnostic(
             "Model returned 200 but empty response",
             Map.merge(diag_base, %{
               step: :validate_response,
               output_tokens: usage[:output_tokens] || 0,
               response_text: text,
               latency_ms: latency
             })
           )}
        end

      {:error, reason} ->
        {:error,
         diagnostic(
           format_error(reason),
           Map.merge(diag_base, %{
             step: :api_call,
             raw_error: inspect(reason, limit: 500)
           })
         )}
    end
  rescue
    e ->
      {:error,
       diagnostic(Exception.message(e), %{
         provider: provider_name,
         model: model,
         step: :api_call,
         exception: e.__struct__,
         stacktrace: Exception.format_stacktrace(__STACKTRACE__) |> String.slice(0, 500)
       })}
  end

  defp diagnostic(message, context) when is_binary(message) do
    %{message: message, context: context}
  end

  defp format_error(%{status: status, response_body: %{"error" => %{"message" => msg}}}),
    do: "HTTP #{status}: #{msg}"

  defp format_error(%{reason: reason}) when is_binary(reason), do: reason
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason, limit: 300)

  @doc "Normalizes model strings for ReqLLM. ARNs are handled by BedrockDirect instead."
  def normalize_model_for_reqllm("ollama:" <> model), do: %{id: model, provider: :openai}
  def normalize_model_for_reqllm(model) when is_binary(model), do: model
  def normalize_model_for_reqllm(model), do: model

  def ensure_aws_credentials do
    profile =
      Config.get([:llm, :keys, :aws_profile]) ||
        Config.get([:llm, :keys, "aws_profile"])

    region =
      Config.get([:llm, :keys, :aws_region]) ||
        Config.get([:llm, :keys, "aws_region"]) ||
        System.get_env("AWS_REGION") || "us-east-1"

    System.put_env("AWS_REGION", region)

    if is_binary(profile) and profile != "" do
      GiTF.Runtime.Keys.load_aws_profile(profile)
    end

    # Register credentials with ReqLLM's bedrock provider
    access_key = System.get_env("AWS_ACCESS_KEY_ID")
    secret_key = System.get_env("AWS_SECRET_ACCESS_KEY")
    session_token = System.get_env("AWS_SESSION_TOKEN")

    if access_key && secret_key do
      creds = %{
        access_key_id: access_key,
        secret_access_key: secret_key,
        region: region
      }

      creds = if session_token, do: Map.put(creds, :session_token, session_token), else: creds

      try do
        ReqLLM.put_key(:aws_bedrock, creds)
      rescue
        _ -> :ok
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  # -- Write -----------------------------------------------------------------

  @doc "Saves current provider config to config.toml and reloads."
  def save!(priority, strategy, provider_configs) do
    global_path = GiTF.global_config_path()
    {:ok, existing} = GiTF.Config.read_config(global_path)

    llm = Map.get(existing, "llm", %{})

    # Update priority and strategy
    llm =
      Map.merge(llm, %{
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

    # Handle AWS profile + region for bedrock
    keys =
      case get_in(provider_configs, ["bedrock", "aws_profile"]) ||
             get_in(provider_configs, ["bedrock", :aws_profile]) do
        profile when is_binary(profile) and profile != "" ->
          Map.put(keys, "aws_profile", profile)

        _ ->
          keys
      end

    keys =
      case get_in(provider_configs, ["bedrock", "aws_region"]) ||
             get_in(provider_configs, ["bedrock", :aws_region]) do
        region when is_binary(region) and region != "" ->
          Map.put(keys, "aws_region", region)

        _ ->
          keys
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
      aws_region: get_aws_region(config),
      api_key_set: has_api_key?(name)
    }
  end

  defp get_provider_config(name) do
    case Config.get([:llm, :providers, String.to_atom(name)]) do
      config when is_map(config) ->
        config

      _ ->
        case Config.get([:llm, :providers, name]) do
          config when is_map(config) -> config
          _ -> %{}
        end
    end
  rescue
    _ -> %{}
  end

  @doc "Returns the API key for a provider from config, or nil."
  def api_key_for(name) do
    key =
      Config.get([:llm, :keys, String.to_atom(name)]) ||
        Config.get([:llm, :keys, name])

    if is_binary(key) and key != "", do: key
  rescue
    _ -> nil
  end

  defp has_api_key?(name), do: api_key_for(name) != nil

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

  defp get_aws_region(config) do
    config[:aws_region] || config["aws_region"] ||
      Config.get([:llm, :keys, :aws_region]) ||
      System.get_env("AWS_REGION") || ""
  rescue
    _ -> ""
  end
end
