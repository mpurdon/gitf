defmodule Hive.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    if Hive.Client.remote?() do
      # Remote mode: thin client, no local services needed
      Supervisor.start_link([], strategy: :one_for_one, name: Hive.Supervisor)
    else
      start_full_app()
    end
  end

  defp start_full_app do
    # Ensure global storage directories exist
    File.mkdir_p!(Path.join(System.user_home!(), ".hive/llm_db"))

    # Determine hive root for config loading
    hive_root = case Hive.hive_dir() do
      {:ok, root} -> root
      _ -> File.cwd!()
    end

    setup_file_logging()

    # Start Config.Provider early so all subsequent code can read config.toml
    Hive.Config.Provider.start_link(hive_root: hive_root)

    Hive.Runtime.Keys.load()

    if Hive.Runtime.ModelResolver.ollama_mode?() do
      Hive.Runtime.ModelResolver.setup_ollama_env()
    end

    validate_config(hive_root)

    Hive.Progress.init()
    Hive.CircuitBreaker.init()
    Hive.Observability.Metrics.init()
    Hive.Telemetry.attach_default_handlers()
    Hive.Observability.Metrics.attach_handlers()

    children = [
      # PubSub MUST be first — everything else depends on it
      {Phoenix.PubSub, name: Hive.PubSub},
      {Hive.Store, data_dir: Application.get_env(:hive, :store_dir, Path.join(File.cwd!, ".hive/store"))},
      {Registry, keys: :unique, name: Hive.Registry},
      {Hive.RateLimiter, name: Hive.RateLimiter, max_tokens: 30, refill_rate: 30, refill_interval: 1_000},
      # The Queen is the brain of the factory - starts automatically now
      {Hive.Queen, hive_root: Application.get_env(:hive, :store_dir, File.cwd!)},
      {Hive.Ingestion.Watchdog, hive_root: File.cwd!()},
      {Hive.PubSubBridge, []}
    ] ++ endpoint_child() ++ [
      {Hive.CombSupervisor, []},
      {Hive.Budget.Watchdog, []},
      {Hive.Plugin.MCPSupervisor, []},
      {Hive.Plugin.ChannelSupervisor, []},
      {Hive.Plugin.Manager, []},
      {Hive.Runtime.GeminiCacheManager, []},
      # ViewModel starts after PubSub; subscribes in handle_continue
      {Hive.ViewModel, []},
      {Hive.Shutdown, []}
    ] ++ optional_children()

    opts = [strategy: :one_for_one, name: Hive.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Only start the web endpoint if the port is available.
  # This allows CLI commands to work when a server is already running.
  defp endpoint_child do
    port = Application.get_env(:hive, Hive.Web.Endpoint)[:http][:port] || 4000

    case :gen_tcp.listen(port, []) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        [{Hive.Web.Endpoint, []}]

      {:error, :eaddrinuse} ->
        require Logger
        Logger.info("Port #{port} already in use, skipping web endpoint. " <>
          "A Hive server may already be running. Use HIVE_SERVER=http://localhost:#{port} for remote mode.")
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
  # with tests that restart Store or other supervised components.
  defp optional_children do
    if function_exported?(Mix, :env, 0) and Mix.env() == :test do
      []
    else
      [
        {Hive.Observability, []},
        {Hive.Drone, []},
        {Hive.Merge.Queue, []}
      ]
    end
  end

  defp validate_config(hive_root) do
    config_path = Path.join([hive_root, ".hive", "config.toml"])

    case Hive.Config.read_config(config_path) do
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
          if get_in(config, ["queen", "max_bees"]) == nil do
            ["queen.max_bees not set (defaulting to 5)" | warnings]
          else
            warnings
          end

        # Check for API keys if in API mode
        warnings =
          if Hive.Runtime.ModelResolver.api_mode?() do
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
    log_file = Path.join(File.cwd!(), "hive.log")

    :logger.add_handler(:hive_file, :logger_std_h, %{
      config: %{file: String.to_charlist(log_file)},
      formatter:
        {Hive.LogFormatter,
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
    Logger.configure(metadata: [:bee_id, :job_id, :quest_id, :comb_id, :component])

    :logger.remove_handler(:default)
  end
end
