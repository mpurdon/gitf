defmodule GiTF.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    if GiTF.Client.remote?() do
      # Remote mode: thin client, no local services needed
      Supervisor.start_link([], strategy: :one_for_one, name: GiTF.Supervisor)
    else
      start_full_app()
    end
  end

  @impl true
  def prep_stop(state) do
    Logger.info("GiTF shutting down gracefully...")
    # Explicitly clean up the MCP socket + PID file.
    # This fires even when terminate/2 on the GenServer is skipped
    # (e.g. escript SIGINT, unclean shutdown).
    GiTF.MCPServer.SocketListener.cleanup()
    state
  end

  defp start_full_app do
    # Store boot timestamp for uptime tracking
    :persistent_term.put(:gitf_boot_time, System.system_time(:second))

    GiTF.Init.init_global()
    File.mkdir_p!(Path.join(GiTF.global_config_dir(), "llm_db"))

    # Determine project root for config overlay (nil if not in a project)
    gitf_root = case GiTF.gitf_dir() do
      {:ok, root} -> root
      _ -> nil
    end

    setup_file_logging()

    # Start Config.Provider early — loads global config, then project overlay
    GiTF.Config.Provider.start_link(gitf_root: gitf_root)

    # Push LLM timeout into ReqLLM's application env so all providers respect it
    llm_timeout = GiTF.Config.Provider.get([:llm, :receive_timeout_ms]) || 60_000
    Application.put_env(:req_llm, :receive_timeout, llm_timeout)

    GiTF.Runtime.Keys.load()

    if GiTF.Runtime.ModelResolver.ollama_mode?() do
      GiTF.Runtime.ModelResolver.setup_ollama_env()
    end

    # Set up AWS credentials for Bedrock if it's in the provider priority
    try do
      if "bedrock" in GiTF.Runtime.ProviderManager.provider_priority() do
        GiTF.Runtime.ProviderManager.ensure_aws_credentials()
      end
    rescue
      _ -> :ok
    end

    validate_config()

    GiTF.Progress.init()
    GiTF.CircuitBreaker.init()
    # Reset any circuit breaker state from previous sessions
    GiTF.CircuitBreaker.reset("api:llm")
    for key <- GiTF.CircuitBreaker.list_open("llm:"), do: GiTF.CircuitBreaker.reset(key)
    GiTF.Observability.Metrics.init()
    GiTF.Telemetry.attach_default_handlers()
    GiTF.Observability.Metrics.attach_handlers()

    # -----------------------------------------------------------------------
    # Supervision tree — grouped by failure domain
    # -----------------------------------------------------------------------
    #
    # Foundation: PubSub, Archive, Registry, TaskSupervisor
    #   → Must start first, everything depends on these
    #
    # Core (rest_for_one): Major, SectorSupervisor, RateLimiter, Watchdogs
    #   → If Major crashes, ghosts/sectors restart too (they depend on Major)
    #
    # Interface (one_for_one): Endpoint, MCP socket, ViewModel, PubSubBridge
    #   → Dashboard/MCP crash never kills the factory
    #
    # Plugins (one_for_one): MCP plugins, channels, plugin manager
    #   → Isolated from everything else
    #
    # Background (one_for_one): Observability, Tachikoma, SyncQueue, Exfil, Cache
    #   → Optional services, skipped in test
    # -----------------------------------------------------------------------

    foundation = [
      {Phoenix.PubSub, name: GiTF.PubSub},
      {GiTF.Archive, data_dir: Application.get_env(:gitf, :store_dir, Path.join(File.cwd!, ".gitf/store"))},
      {Registry, keys: :unique, name: GiTF.Registry},
      {Task.Supervisor, name: GiTF.TaskSupervisor}
    ]

    core = %{
      id: GiTF.Core.Supervisor,
      type: :supervisor,
      start: {Supervisor, :start_link, [
        [
          {GiTF.RateLimiter, name: GiTF.RateLimiter, max_tokens: 30, refill_rate: 30, refill_interval: 1_000},
          {GiTF.Major, gitf_root: Application.get_env(:gitf, :store_dir, File.cwd!)},
          {GiTF.SectorSupervisor, []},
          {GiTF.Budget.Watchdog, []},
          {GiTF.Ingestion.Watchdog, gitf_root: File.cwd!()}
        ],
        [strategy: :rest_for_one, name: GiTF.Core.Supervisor]
      ]}
    }

    interface_children =
      endpoint_child() ++ [
        {GiTF.MCPServer.SocketListener, []},
        {GiTF.ViewModel, []},
        {GiTF.PubSubBridge, []}
      ]

    interface = %{
      id: GiTF.Interface.Supervisor,
      type: :supervisor,
      start: {Supervisor, :start_link, [
        interface_children,
        [strategy: :one_for_one, name: GiTF.Interface.Supervisor]
      ]}
    }

    plugins = %{
      id: GiTF.Plugin.Supervisor,
      type: :supervisor,
      start: {Supervisor, :start_link, [
        [
          {GiTF.Plugin.MCPSupervisor, []},
          {GiTF.Plugin.ChannelSupervisor, []},
          {GiTF.Plugin.Manager, []}
        ],
        [strategy: :one_for_one, name: GiTF.Plugin.Supervisor]
      ]}
    }

    children = foundation ++ [core, interface, plugins] ++ background_children()

    opts = [strategy: :one_for_one, name: GiTF.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Start the web endpoint, retrying briefly if the port is still releasing
  # from a previous Ctrl+C abort.
  defp endpoint_child do
    port = Application.get_env(:gitf, GiTF.Web.Endpoint)[:http][:port] || 4000
    try_bind_port(port, 3)
  end

  defp try_bind_port(_port, 0) do
    Logger.info("Port still in use after retries, skipping web endpoint.")
    []
  end

  defp try_bind_port(port, retries) do
    case :gen_tcp.listen(port, [reuseaddr: true]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        [{GiTF.Web.Endpoint, []}]

      {:error, :eaddrinuse} ->
        if retries > 1 do
          Logger.info("Port #{port} busy, waiting for release (#{retries - 1} retries left)...")
          Process.sleep(1000)
          try_bind_port(port, retries - 1)
        else
          Logger.info("Port #{port} already in use, skipping web endpoint. " <>
            "A GiTF server may already be running.")
          []
        end

      {:error, :eacces} ->
        Logger.warning("Permission denied for port #{port}. Try a port above 1024.")
        []

      {:error, reason} ->
        Logger.warning("Cannot bind to port #{port}: #{inspect(reason)}. Skipping web endpoint.")
        []
    end
  end

  # Background services — skip in test to avoid conflicts
  defp background_children do
    bg = [
      {GiTF.Runtime.GeminiCacheManager, []},
      {GiTF.Exfil, []}
    ]

    optional =
      if function_exported?(Mix, :env, 0) and Mix.env() == :test do
        []
      else
        [
          {GiTF.Observability, []},
          {GiTF.Tachikoma, []},
          {GiTF.Sync.Queue, []}
        ]
      end

    bg_children = bg ++ optional

    [%{
      id: GiTF.Background.Supervisor,
      type: :supervisor,
      start: {Supervisor, :start_link, [
        bg_children,
        [strategy: :one_for_one, name: GiTF.Background.Supervisor]
      ]}
    }]
  end

  defp validate_config do
    alias GiTF.Config.Provider

    warnings = []

    warnings =
      if Provider.get([:costs, :budget_usd]) == nil do
        ["costs.budget_usd not set (defaulting to $10)" | warnings]
      else
        warnings
      end

    warnings =
      if Provider.get([:major, :max_ghosts]) == nil do
        ["queen.max_ghosts not set (defaulting to 5)" | warnings]
      else
        warnings
      end

    warnings =
      if GiTF.Runtime.ModelResolver.api_mode?() do
        has_google = (Provider.get([:llm, :keys, :google]) || "") != ""
        has_anthropic = (Provider.get([:llm, :keys, :anthropic]) || "") != ""
        env_google = System.get_env("GOOGLE_API_KEY") || System.get_env("GEMINI_API_KEY")
        env_anthropic = System.get_env("ANTHROPIC_API_KEY")

        if not has_google and not has_anthropic and env_google == nil and env_anthropic == nil do
          ["No API keys found in config or environment — API calls will fail" | warnings]
        else
          warnings
        end
      else
        warnings
      end

    if warnings != [] do
      Enum.each(warnings, fn w -> Logger.warning("Config: #{w}") end)
    end
  rescue
    _ -> :ok
  end

  defp setup_file_logging do
    log_file = Path.join(File.cwd!(), "section.log")

    :logger.add_handler(:gitf_file, :logger_std_h, %{
      config: %{file: String.to_charlist(log_file)},
      formatter:
        {GiTF.LogFormatter,
         %{
           template: [
             :time, ~c" ", :level, ~c" ",
             :msg,
             ~c" ", :mfa,
             ~c"\n"
           ],
           single_line: true
         }}
    })

    # Configure Elixir Logger to forward metadata keys
    Logger.configure(metadata: [:ghost_id, :op_id, :mission_id, :sector_id, :component])

    :logger.remove_handler(:default)
  end
end
