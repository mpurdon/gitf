defmodule GiTF.Plugin.Manager do
  @moduledoc """
  Plugin lifecycle GenServer with hot reload support.

  Discovers built-in plugins at startup, manages registration/unregistration,
  and supports hot-reloading of plugins at runtime. PubSub broadcasts on
  plugin changes so the TUI can refresh.
  """

  use GenServer

  require Logger

  @builtin_models [
    GiTF.Plugin.Builtin.Models.Claude,
    GiTF.Plugin.Builtin.Models.Copilot,
    GiTF.Plugin.Builtin.Models.Kimi,
    GiTF.Plugin.Builtin.Models.ReqLLMProvider
  ]
  @builtin_themes [GiTF.Plugin.Builtin.Themes.Default]
  @builtin_commands [
    GiTF.Plugin.Builtin.Commands.Help,
    GiTF.Plugin.Builtin.Commands.Quit,
    GiTF.Plugin.Builtin.Commands.Quest,
    GiTF.Plugin.Builtin.Commands.Bee,
    GiTF.Plugin.Builtin.Commands.PluginCmd
  ]
  @builtin_channels [
    GiTF.Plugin.Builtin.Channels.Telegram
  ]
  @builtin_tool_providers [
    GiTF.Plugin.Builtin.ToolProviders.ProjectContext,
    GiTF.Plugin.Builtin.ToolProviders.Workspace
  ]

  # -- Public API ------------------------------------------------------------

  @doc "Starts the plugin manager."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Gets a plugin by type and name."
  @spec get(atom(), String.t()) :: {:ok, module()} | :error
  def get(type, name) do
    GiTF.Plugin.Registry.lookup(type, name)
  end

  @doc "Lists all plugins of a given type."
  @spec list(atom()) :: [{String.t(), module()}]
  def list(type) do
    GiTF.Plugin.Registry.list(type)
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
    :persistent_term.get(:gitf_active_theme, %{})
  rescue
    ArgumentError -> %{}
  end

  # -- GenServer callbacks ---------------------------------------------------

  @impl true
  def init(_opts) do
    GiTF.Plugin.Registry.init()
    register_builtins()
    set_default_theme()

    GiTF.Telemetry.emit([:gitf, :plugin, :loaded], %{}, %{
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
    case GiTF.Plugin.Registry.lookup(type, name) do
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
    for module <- @builtin_channels, do: do_load(module)
    for module <- @builtin_tool_providers, do: do_load(module)
    load_external_mcp_servers()
  end

  defp load_external_mcp_servers do
    global_mcp_config = GiTF.Config.Provider.get([:plugins, :mcp]) || %{}
    local_mcp_config = load_local_mcp_json()
    mcp_config = Map.merge(global_mcp_config, local_mcp_config)

    Enum.each(mcp_config, fn {name, config} ->
      if is_map(config) do
        name_str = to_string(name)
        command = config[:command] || config["command"]
        args = config[:args] || config["args"] || []
        env = config[:env] || config["env"] || %{}

        if command do
          module_name = Module.concat(GiTF.Plugin.External.MCP, Macro.camelize(name_str))

          {:module, module, _, _} =
            Module.create(
              module_name,
              quote do
                @behaviour GiTF.Plugin.MCP

                def __plugin_type__, do: :mcp
                def name, do: unquote(name_str)
                def description, do: "External MCP server: #{unquote(name_str)}"
                def command, do: {unquote(command), unquote(Macro.escape(args))}

                def env do
                  unquote(Macro.escape(env))
                  |> Enum.into(%{}, fn {k, v} ->
                    {to_string(k), interpolate_env(to_string(v))}
                  end)
                end

                defp interpolate_env(value) do
                  Regex.replace(~r/\$\{(\w+)\}/, value, fn _, var ->
                    System.get_env(var) || ""
                  end)
                end
              end,
              Macro.Env.location(__ENV__)
            )

          do_load(module)
        else
          Logger.warning("External MCP #{name_str}: missing 'command' in config")
        end
      end
    end)
  rescue
    e ->
      Logger.warning("Failed to load external MCP servers: #{Exception.message(e)}")
  end

  defp load_local_mcp_json do
    case GiTF.gitf_dir() do
      {:ok, root} ->
        # Look for .claude.json, mcp.json, or .mcp.json
        paths = [
          Path.join(root, ".claude.json"),
          Path.join(root, "mcp.json"),
          Path.join(root, ".mcp.json"),
          Path.join(root, ".gitf/mcp.json")
        ]

        Enum.find_value(paths, %{}, fn path ->
          case File.read(path) do
            {:ok, content} ->
              case Jason.decode(content) do
                {:ok, %{"mcpServers" => servers}} when is_map(servers) -> servers
                {:ok, servers} when is_map(servers) -> servers
                _ -> nil
              end
            _ -> nil
          end
        end) || %{}

      _ -> %{}
    end
  end

  defp do_load(module) do
    with {:ok, type} <- get_plugin_type(module),
         {:ok, name} <- get_plugin_name(module) do
      GiTF.Plugin.Registry.register(type, name, module)

      # Start supervised processes for MCP and channel plugins
      case type do
        :mcp ->
          GiTF.Plugin.MCPSupervisor.start_child(module)

        :channel ->
          config = GiTF.Config.Provider.get([:plugins, :channels, String.to_atom(name)]) || %{}
          GiTF.Plugin.ChannelSupervisor.start_child(module, config)

        :tool_provider ->
          :ok

        _ ->
          :ok
      end

      Phoenix.PubSub.broadcast(
        GiTF.PubSub,
        "plugins:loaded",
        {:plugin_loaded, type, name, module}
      )

      GiTF.Telemetry.emit([:gitf, :plugin, :loaded], %{}, %{
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
    case GiTF.Plugin.Registry.lookup(type, name) do
      {:ok, module} ->
        # Call optional exfil callback
        if function_exported?(module, :shutdown, 0), do: module.shutdown()

        GiTF.Plugin.Registry.unregister(type, name)
        Phoenix.PubSub.broadcast(GiTF.PubSub, "plugins:unloaded", {:plugin_unloaded, type, name})
        GiTF.Telemetry.emit([:gitf, :plugin, :unloaded], %{}, %{type: type, name: name})
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
        implements?(module, GiTF.Plugin.Model) -> {:ok, :model}
        implements?(module, GiTF.Plugin.Theme) -> {:ok, :theme}
        implements?(module, GiTF.Plugin.Command) -> {:ok, :command}
        implements?(module, GiTF.Plugin.LSP) -> {:ok, :lsp}
        implements?(module, GiTF.Plugin.MCP) -> {:ok, :mcp}
        implements?(module, GiTF.Plugin.Channel) -> {:ok, :channel}
        implements?(module, GiTF.Plugin.ToolProvider) -> {:ok, :tool_provider}
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
    case GiTF.Plugin.Registry.lookup(:theme, "default") do
      {:ok, module} ->
        :persistent_term.put(:gitf_active_theme, module.palette())

      :error ->
        :persistent_term.put(:gitf_active_theme, %{})
    end
  end
end
