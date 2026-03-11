defmodule GiTF.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    if GiTF.Client.remote?() do
      # Remote mode: thin client, no local services needed
      Supervisor.start_link([], strategy: :one_for_one, name: GiTF.Supervisor)
    else
      start_full_app()
    end
  end

  defp start_full_app do
    # Ensure global storage directories exist
    File.mkdir_p!(Path.join(System.user_home!(), ".gitf/llm_db"))

    # Determine gitf root for config loading
    gitf_root = case GiTF.gitf_dir() do
      {:ok, root} -> root
      _ -> File.cwd!()
    end

    setup_file_logging()

    # Start Config.Provider early so all subsequent code can read config.toml
    GiTF.Config.Provider.start_link(gitf_root: gitf_root)

    GiTF.Runtime.Keys.load()

    if GiTF.Runtime.ModelResolver.ollama_mode?() do
      GiTF.Runtime.ModelResolver.setup_ollama_env()
    end

    validate_config(gitf_root)

    GiTF.Progress.init()
    GiTF.CircuitBreaker.init()
    GiTF.Observability.Metrics.init()
    GiTF.Telemetry.attach_default_handlers()
    GiTF.Observability.Metrics.attach_handlers()

    children = [
      # PubSub MUST be first — everything else depends on it
      {Phoenix.PubSub, name: GiTF.PubSub},
      {GiTF.Archive, data_dir: Application.get_env(:gitf, :store_dir, Path.join(File.cwd!, ".gitf/store"))},
      {Registry, keys: :unique, name: GiTF.Registry},
      {GiTF.RateLimiter, name: GiTF.RateLimiter, max_tokens: 30, refill_rate: 30, refill_interval: 1_000},
      # The Major is the brain of the factory - starts automatically now
      {GiTF.Major, gitf_root: Application.get_env(:gitf, :store_dir, File.cwd!)},
      {GiTF.Ingestion.Watchdog, gitf_root: File.cwd!()},
      {GiTF.PubSubBridge, []}
    ] ++ endpoint_child() ++ [
      {GiTF.SectorSupervisor, []},
      {GiTF.Budget.Watchdog, []},
      {GiTF.Plugin.MCPSupervisor, []},
      {GiTF.Plugin.ChannelSupervisor, []},
      {GiTF.Plugin.Manager, []},
      {GiTF.Runtime.GeminiCacheManager, []},
      # ViewModel starts after PubSub; subscribes in handle_continue
      {GiTF.ViewModel, []},
      {GiTF.Exfil, []}
    ] ++ optional_children()

    opts = [strategy: :one_for_one, name: GiTF.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Only start the web endpoint if the port is available.
  # This allows CLI commands to work when a server is already running.
  defp endpoint_child do
    port = Application.get_env(:gitf, GiTF.Web.Endpoint)[:http][:port] || 4000

    case :gen_tcp.listen(port, []) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        [{GiTF.Web.Endpoint, []}]

      {:error, :eaddrinuse} ->
        require Logger
        Logger.info("Port #{port} already in use, skipping web endpoint. " <>
          "A GiTF server may already be running. Use GITF_SERVER=http://localhost:#{port} for remote mode.")
        []

      {:error, :eacces} ->
        require Logger
        Logger.warning("Permission denied for port #{port}. Try a port above 1024.")
        []

      {:error, reason} ->
        require Logger
        Logger.warning("Cannot bind to port #{port}: #{inspect(reason)}. Skipping web endpoint.")
        []
    end
  end

  # Background monitoring processes — skip in test to avoid conflicts
  # with tests that restart Archive or other supervised components.
  defp optional_children do
    if function_exported?(Mix, :env, 0) and Mix.env() == :test do
      []
    else
      [
        {GiTF.Observability, []},
        {GiTF.Tachikoma, []},
        {GiTF.Sync.Queue, []}
      ]
    end
  end

  defp validate_config(gitf_root) do
    config_path = Path.join([gitf_root, ".gitf", "config.toml"])

    case GiTF.Config.read_config(config_path) do
      {:ok, config} ->
        # Warn about missing critical config sections
        warnings = []

        warnings =
          if get_in(config, ["costs", "budget_usd"]) == nil do
            ["costs.budget_usd not set (defaulting to $10)" | warnings]
          else
            warnings
          end

        warnings =
          if get_in(config, ["major", "max_ghosts"]) == nil do
            ["queen.max_ghosts not set (defaulting to 5)" | warnings]
          else
            warnings
          end

        # Check for API keys if in API mode
        warnings =
          if GiTF.Runtime.ModelResolver.api_mode?() do
            has_google = (get_in(config, ["llm", "keys", "google"]) || "") != ""
            has_anthropic = (get_in(config, ["llm", "keys", "anthropic"]) || "") != ""
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
          require Logger
          Enum.each(warnings, fn w -> Logger.warning("Config: #{w}") end)
        end

      {:error, reason} ->
        require Logger
        Logger.warning("Config: cannot read #{config_path}: #{inspect(reason)}, using defaults")
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
