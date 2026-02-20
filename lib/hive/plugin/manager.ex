defmodule Hive.Plugin.Manager do
  @moduledoc """
  Plugin lifecycle GenServer with hot reload support.

  Discovers built-in plugins at startup, manages registration/unregistration,
  and supports hot-reloading of plugins at runtime. PubSub broadcasts on
  plugin changes so the TUI can refresh.
  """

  use GenServer

  require Logger

  @builtin_models [
    Hive.Plugin.Builtin.Models.Claude,
    Hive.Plugin.Builtin.Models.Copilot,
    Hive.Plugin.Builtin.Models.Kimi
  ]
  @builtin_themes [Hive.Plugin.Builtin.Themes.Default]
  @builtin_commands [
    Hive.Plugin.Builtin.Commands.Help,
    Hive.Plugin.Builtin.Commands.Quit,
    Hive.Plugin.Builtin.Commands.Quest,
    Hive.Plugin.Builtin.Commands.Bee,
    Hive.Plugin.Builtin.Commands.PluginCmd,
    Hive.Plugin.Builtin.Commands.Council
  ]

  # -- Public API ------------------------------------------------------------

  @doc "Starts the plugin manager."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Gets a plugin by type and name."
  @spec get(atom(), String.t()) :: {:ok, module()} | :error
  def get(type, name) do
    Hive.Plugin.Registry.lookup(type, name)
  end

  @doc "Lists all plugins of a given type."
  @spec list(atom()) :: [{String.t(), module()}]
  def list(type) do
    Hive.Plugin.Registry.list(type)
  end

  @doc "Loads a plugin module at runtime."
  @spec load_plugin(module()) :: :ok | {:error, term()}
  def load_plugin(module) do
    GenServer.call(__MODULE__, {:load, module})
  end

  @doc "Loads a plugin from a .ex file path."
  @spec load_plugin_file(String.t()) :: :ok | {:error, term()}
  def load_plugin_file(path) do
    GenServer.call(__MODULE__, {:load_file, path})
  end

  @doc "Unloads a plugin by type and name."
  @spec unload_plugin(atom(), String.t()) :: :ok | {:error, term()}
  def unload_plugin(type, name) do
    GenServer.call(__MODULE__, {:unload, type, name})
  end

  @doc "Reloads a plugin (unload + load)."
  @spec reload_plugin(atom(), String.t()) :: :ok | {:error, term()}
  def reload_plugin(type, name) do
    GenServer.call(__MODULE__, {:reload, type, name})
  end

  @doc "Returns the active theme palette, reading from persistent_term."
  @spec active_theme() :: map()
  def active_theme do
    :persistent_term.get(:hive_active_theme, %{})
  rescue
    ArgumentError -> %{}
  end

  # -- GenServer callbacks ---------------------------------------------------

  @impl true
  def init(_opts) do
    Hive.Plugin.Registry.init()
    register_builtins()
    set_default_theme()

    Hive.Telemetry.emit([:hive, :plugin, :loaded], %{}, %{
      type: :builtin,
      name: "all",
      module: __MODULE__
    })

    {:ok, %{}}
  end

  @impl true
  def handle_call({:load, module}, _from, state) do
    result = do_load(module)
    {:reply, result, state}
  end

  def handle_call({:load_file, path}, _from, state) do
    result =
      try do
        [{module, _}] = Code.compile_file(path)
        do_load(module)
      rescue
        e -> {:error, {:compile_error, Exception.message(e)}}
      end

    {:reply, result, state}
  end

  def handle_call({:unload, type, name}, _from, state) do
    result = do_unload(type, name)
    {:reply, result, state}
  end

  def handle_call({:reload, type, name}, _from, state) do
    case Hive.Plugin.Registry.lookup(type, name) do
      {:ok, module} ->
        do_unload(type, name)
        result = do_load(module)
        {:reply, result, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # -- Private ---------------------------------------------------------------

  defp register_builtins do
    for module <- @builtin_models, do: do_load(module)
    for module <- @builtin_themes, do: do_load(module)
    for module <- @builtin_commands, do: do_load(module)
  end

  defp do_load(module) do
    with {:ok, type} <- get_plugin_type(module),
         {:ok, name} <- get_plugin_name(module) do
      Hive.Plugin.Registry.register(type, name, module)

      # Start supervised processes for MCP and channel plugins
      case type do
        :mcp ->
          Hive.Plugin.MCPSupervisor.start_child(module)

        :channel ->
          config = Hive.Config.Provider.get([:plugins, :channels, String.to_atom(name)]) || %{}
          Hive.Plugin.ChannelSupervisor.start_child(module, config)

        _ ->
          :ok
      end

      Phoenix.PubSub.broadcast(
        Hive.PubSub,
        "plugins:loaded",
        {:plugin_loaded, type, name, module}
      )

      Hive.Telemetry.emit([:hive, :plugin, :loaded], %{}, %{
        type: type,
        name: name,
        module: module
      })

      :ok
    end
  rescue
    e ->
      Logger.warning("Failed to load plugin #{inspect(module)}: #{Exception.message(e)}")
      {:error, {:load_failed, Exception.message(e)}}
  end

  defp do_unload(type, name) do
    case Hive.Plugin.Registry.lookup(type, name) do
      {:ok, module} ->
        # Call optional shutdown callback
        if function_exported?(module, :shutdown, 0), do: module.shutdown()

        Hive.Plugin.Registry.unregister(type, name)
        Phoenix.PubSub.broadcast(Hive.PubSub, "plugins:unloaded", {:plugin_unloaded, type, name})
        Hive.Telemetry.emit([:hive, :plugin, :unloaded], %{}, %{type: type, name: name})
        :ok

      :error ->
        {:error, :not_found}
    end
  end

  defp get_plugin_type(module) do
    if function_exported?(module, :__plugin_type__, 0) do
      {:ok, module.__plugin_type__()}
    else
      # Infer from behaviour
      cond do
        implements?(module, Hive.Plugin.Model) -> {:ok, :model}
        implements?(module, Hive.Plugin.Theme) -> {:ok, :theme}
        implements?(module, Hive.Plugin.Command) -> {:ok, :command}
        implements?(module, Hive.Plugin.LSP) -> {:ok, :lsp}
        implements?(module, Hive.Plugin.MCP) -> {:ok, :mcp}
        implements?(module, Hive.Plugin.Channel) -> {:ok, :channel}
        true -> {:error, :unknown_plugin_type}
      end
    end
  end

  defp get_plugin_name(module) do
    if function_exported?(module, :name, 0) do
      {:ok, module.name()}
    else
      {:error, :no_name}
    end
  end

  defp implements?(module, behaviour) do
    behaviours =
      module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    behaviour in behaviours
  rescue
    _ -> false
  end

  defp set_default_theme do
    case Hive.Plugin.Registry.lookup(:theme, "default") do
      {:ok, module} ->
        :persistent_term.put(:hive_active_theme, module.palette())

      :error ->
        :persistent_term.put(:hive_active_theme, %{})
    end
  end
end
