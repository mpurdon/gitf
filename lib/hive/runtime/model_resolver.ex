defmodule Hive.Runtime.ModelResolver do
  @moduledoc """
  Centralized model name resolution.

  Maps tier names ("opus", "sonnet", "haiku") to provider-specific model
  specs (e.g. "anthropic:claude-opus-4-6", "google:gemini-2.5-pro").

  The mapping is configured in `:hive, :llm, :default_models` and can
  be overridden at runtime. Provider-qualified names like
  "anthropic:claude-opus-4-6" pass through unchanged.

  ## Execution Mode

  Returns `:api`, `:cli`, or `:ollama` based on (in priority order):
  1. `HIVE_EXECUTION_MODE` env var
  2. Hive config `execution_mode`
  3. Application config `:hive, :llm, :execution_mode`
  4. Default: `:api`

  The `:ollama` mode is a convenience that behaves like `:api` but
  auto-configures `OPENAI_API_BASE` for a local Ollama instance and
  maps default model tiers to local model names.
  """

  @default_models %{
    "opus" => "google:gemini-2.5-pro",
    "sonnet" => "google:gemini-2.5-flash",
    "haiku" => "google:gemini-2.0-flash",
    "fast" => "google:gemini-2.0-flash",
    # Legacy Claude names (backwards compat for explicit requests)
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

  - `"opus"` → configured opus model (e.g. `"anthropic:claude-opus-4-6"`)
  - `"sonnet"` → configured sonnet model
  - `"claude-sonnet"` → maps to provider-qualified name
  - `"anthropic:claude-opus-4-6"` → passthrough
  - `"google:gemini-2.0-flash"` → passthrough
  """
  @spec resolve(String.t()) :: String.t()
  def resolve(name) when is_binary(name) do
    # If already provider-qualified, pass through
    if String.contains?(name, ":") do
      name
    else
      models = configured_models()
      Map.get(models, name, name)
    end
  end

  @doc """
  Returns the current execution mode: `:api`, `:cli`, `:ollama`, or `:bedrock`.

  Checked in priority order:
  1. `HIVE_EXECUTION_MODE` env var
  2. Hive config file `execution_mode`
  3. Application config `:hive, :llm, :execution_mode`
  4. Default: `:api`
  """
  @spec execution_mode() :: :api | :cli | :ollama | :bedrock
  def execution_mode do
    case System.get_env("HIVE_EXECUTION_MODE") do
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

    base = cond do
      mode == :ollama -> Map.merge(@default_models, mode_defaults(:ollama))
      mode == :bedrock -> Map.merge(@default_models, mode_defaults(:bedrock))
      true -> @default_models
    end

    case Application.get_env(:hive, :llm) do
      nil ->
        base

      config ->
        custom = config[:default_models] || %{}
        custom_string_keys = Map.new(custom, fn {k, v} -> {to_string(k), v} end)
        Map.merge(base, custom_string_keys)
    end
  end

  @ollama_defaults %{
    "opus" => "openai:qwen2.5-coder:32b",
    "sonnet" => "openai:qwen2.5-coder:14b",
    "haiku" => "openai:qwen2.5-coder:7b",
    "fast" => "openai:qwen2.5-coder:7b"
  }

  @bedrock_defaults %{
    "opus" => "bedrock:anthropic.claude-sonnet-4-6-20250514-v1:0",
    "sonnet" => "bedrock:anthropic.claude-sonnet-4-6-20250514-v1:0",
    "haiku" => "bedrock:anthropic.claude-haiku-4-5-20251001-v1:0",
    "fast" => "bedrock:anthropic.claude-haiku-4-5-20251001-v1:0"
  }

  defp mode_defaults(:ollama) do
    case Hive.Config.Provider.get([:llm, :ollama_models]) do
      nil -> @ollama_defaults
      custom when is_map(custom) -> Map.merge(@ollama_defaults, Map.new(custom, fn {k, v} -> {to_string(k), v} end))
      _ -> @ollama_defaults
    end
  rescue
    _ -> @ollama_defaults
  end

  defp mode_defaults(:bedrock) do
    case Hive.Config.Provider.get([:llm, :bedrock_models]) do
      nil -> @bedrock_defaults
      custom when is_map(custom) -> Map.merge(@bedrock_defaults, Map.new(custom, fn {k, v} -> {to_string(k), v} end))
      _ -> @bedrock_defaults
    end
  rescue
    _ -> @bedrock_defaults
  end

  @doc """
  Returns a fallback model for the given model spec.

  Degrades gracefully: opus → sonnet → haiku. Returns nil if no fallback.
  Used when the primary model fails (API down, billing limit, etc.).
  """
  @spec fallback(String.t()) :: String.t() | nil
  def fallback(model_spec) do
    resolved = resolve(model_spec)
    models = configured_models()

    # Build a reverse lookup: model_spec → tier name
    tier = Enum.find_value(models, fn {tier_name, spec} ->
      if spec == resolved, do: tier_name
    end)

    case tier do
      "opus" -> resolve("sonnet")
      "sonnet" -> resolve("haiku")
      _ -> nil
    end
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

    case String.split(resolved, ":", parts: 2) do
      [provider, _model] -> provider
      _ -> "google"
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
      Hive.Config.Provider.get([:llm, :execution_mode]) ||
        Hive.Config.Provider.get([:execution_mode])

    parse_mode(mode)
  rescue
    _ -> nil
  end

  defp app_config_mode do
    get_in(Application.get_env(:hive, :llm, []), [:execution_mode])
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
