defmodule Hive.Runtime.Models do
  @moduledoc """
  Central facade for all model operations.

  Resolves the active model plugin from config/options and delegates
  every call through it. All call sites should use this module instead
  of calling `Hive.Runtime.Claude` directly.

  ## Resolution order

  1. Explicit `:model_plugin` in opts (module or name string)
  2. Config `plugins.models.default` via `Hive.Config.Provider`
  3. Fallback: `"claude"`
  """

  @default_plugin_name "claude"
  @default_plugin Hive.Plugin.Builtin.Models.Claude

  # -- Core dispatch -----------------------------------------------------------

  @doc """
  Spawns a headless model session with the given prompt.

  Resolves the active plugin and delegates to its `spawn_headless/3`.
  """
  @spec spawn_headless(String.t(), String.t(), keyword()) :: {:ok, port()} | {:error, term()}
  def spawn_headless(prompt, cwd, opts \\ []) do
    {:ok, plugin} = resolve_plugin(opts)
    service_key = plugin_service_key(plugin)

    Hive.CircuitBreaker.call(service_key, fn ->
      plugin.spawn_headless(prompt, cwd, opts)
    end)
  end

  @doc """
  Spawns an interactive model session.

  Resolves the active plugin and delegates to its `spawn_interactive/2`.
  """
  @spec spawn_interactive(String.t(), keyword()) :: {:ok, port()} | {:error, term()}
  def spawn_interactive(cwd, opts \\ []) do
    {:ok, plugin} = resolve_plugin(opts)
    service_key = plugin_service_key(plugin)

    Hive.CircuitBreaker.call(service_key, fn ->
      plugin.spawn_interactive(cwd, opts)
    end)
  end

  @doc """
  Parses raw output data into structured events.

  Resolves the active plugin and delegates to its `parse_output/1`.
  """
  @spec parse_output(binary(), keyword()) :: [map()]
  def parse_output(data, opts \\ []) do
    {:ok, plugin} = resolve_plugin(opts)
    plugin.parse_output(data)
  end

  @doc """
  Locates the model provider's executable.

  Falls back to `{:error, :not_found}` if the plugin doesn't implement
  `find_executable/0`.
  """
  @spec find_executable(keyword()) :: {:ok, String.t()} | {:error, :not_found}
  def find_executable(opts \\ []) do
    {:ok, plugin} = resolve_plugin(opts)

    if function_exported?(plugin, :find_executable, 0) do
      plugin.find_executable()
    else
      {:error, :not_found}
    end
  end

  @doc """
  Extracts cost data from a list of parsed events.

  Falls back to `Hive.Runtime.StreamParser.extract_costs/1` if the plugin
  doesn't implement `extract_costs/1`.
  """
  @spec extract_costs([map()], keyword()) :: [map()]
  def extract_costs(events, opts \\ []) do
    {:ok, plugin} = resolve_plugin(opts)

    if function_exported?(plugin, :extract_costs, 1) do
      plugin.extract_costs(events)
    else
      Hive.Runtime.StreamParser.extract_costs(events)
    end
  end

  @doc """
  Extracts a session ID from parsed events.

  Returns `nil` if the plugin doesn't implement `extract_session_id/1`
  or if no session ID is present in the events.
  """
  @spec extract_session_id([map()], keyword()) :: String.t() | nil
  def extract_session_id(events, opts \\ []) do
    {:ok, plugin} = resolve_plugin(opts)

    if function_exported?(plugin, :extract_session_id, 1) do
      plugin.extract_session_id(events)
    else
      nil
    end
  end

  @doc """
  Get the context limit for a model.
  
  Returns the maximum context window size in tokens.
  """
  @spec get_context_limit(String.t(), keyword()) :: {:ok, integer()} | {:error, term()}
  def get_context_limit(model, opts \\ []) do
    {:ok, plugin} = resolve_plugin(opts)

    if function_exported?(plugin, :get_context_limit, 1) do
      plugin.get_context_limit(model)
    else
      # Default to 200k for Claude models
      {:ok, 200_000}
    end
  end

  @doc """
  Get information about a specific model.
  """
  @spec get_model_info(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_model_info(model, opts \\ []) do
    {:ok, plugin} = resolve_plugin(opts)

    if function_exported?(plugin, :get_model_info, 1) do
      plugin.get_model_info(model)
    else
      {:error, :not_supported}
    end
  end

  @doc """
  List all available models from the active plugin.
  """
  @spec list_available_models(keyword()) :: [String.t()]
  def list_available_models(opts \\ []) do
    {:ok, plugin} = resolve_plugin(opts)

    if function_exported?(plugin, :list_available_models, 0) do
      plugin.list_available_models()
    else
      nil
    end
  end

  @doc """
  Extracts progress updates from parsed events.

  Returns an empty list if the plugin doesn't implement
  `progress_from_events/1`.
  """
  @spec progress_from_events([map()], keyword()) :: [map()]
  def progress_from_events(events, opts \\ []) do
    {:ok, plugin} = resolve_plugin(opts)

    if function_exported?(plugin, :progress_from_events, 1) do
      plugin.progress_from_events(events)
    else
      []
    end
  end

  # -- Settings ----------------------------------------------------------------

  @doc """
  Returns workspace setup map for a bee or queen, or nil if the plugin
  doesn't provide workspace configuration.
  """
  @spec workspace_setup(String.t(), String.t(), keyword()) :: map() | nil
  def workspace_setup(bee_or_queen, hive_root, opts \\ []) do
    {:ok, plugin} = resolve_plugin(opts)

    if function_exported?(plugin, :workspace_setup, 2) do
      plugin.workspace_setup(bee_or_queen, hive_root)
    else
      nil
    end
  end

  # -- Config ------------------------------------------------------------------

  @doc """
  Returns the pricing table from the active model plugin.

  Falls back to an empty map if the plugin doesn't implement `pricing/0`.
  """
  @spec pricing(keyword()) :: map()
  def pricing(opts \\ []) do
    {:ok, plugin} = resolve_plugin(opts)

    if function_exported?(plugin, :pricing, 0) do
      plugin.pricing()
    else
      %{}
    end
  end

  @doc """
  Reads per-provider config from `plugins.models.providers.<name>`.
  """
  @spec provider_config(String.t()) :: map()
  def provider_config(name) do
    Hive.Config.Provider.get([:plugins, :models, :providers, String.to_atom(name)]) || %{}
  rescue
    _ -> %{}
  end

  @doc """
  Returns the default model plugin name from config.
  """
  @spec default_name() :: String.t()
  def default_name do
    Hive.Config.Provider.get([:plugins, :models, :default]) || @default_plugin_name
  rescue
    _ -> @default_plugin_name
  end

  # -- Resolution --------------------------------------------------------------

  @doc """
  Resolves the active model plugin module.

  Resolution order:
  1. `:model_plugin` option (module or name string)
  2. Config `plugins.models.default`
  3. Hardcoded `"claude"` fallback

  Returns `{:ok, module}` or `{:error, :plugin_not_found}`.
  """
  @spec resolve_plugin(keyword()) :: {:ok, module()} | {:error, :plugin_not_found}
  def resolve_plugin(opts \\ []) do
    case Keyword.get(opts, :model_plugin) do
      nil ->
        resolve_by_name(default_name())

      name when is_binary(name) ->
        resolve_by_name(name)

      module when is_atom(module) ->
        {:ok, module}
    end
  end

  defp resolve_by_name(name) do
    case Hive.Plugin.Registry.lookup(:model, name) do
      {:ok, module} -> {:ok, module}
      :error -> {:ok, @default_plugin}
    end
  end

  defp plugin_service_key(plugin) do
    plugin
    |> Module.split()
    |> List.last()
    |> String.downcase()
    |> Kernel.<>("-api")
  end
end
