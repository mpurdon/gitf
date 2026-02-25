defmodule Hive.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    setup_file_logging()
    Hive.Runtime.Keys.load()
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
      # The Queen is the brain of the factory - starts automatically now
      {Hive.Queen, hive_root: Application.get_env(:hive, :store_dir, File.cwd!)},
      {Hive.Ingestion.Watchdog, hive_root: File.cwd!()},
      {Hive.PubSubBridge, []},
      {Hive.Web.Endpoint, []},
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

  # Background monitoring processes — skip in test to avoid conflicts
  # with tests that restart Store or other supervised components.
  defp optional_children do
    if function_exported?(Mix, :env, 0) and Mix.env() == :test do
      []
    else
      [
        {Hive.Observability, []},
        {Hive.Drone, []}
      ]
    end
  end

  defp setup_file_logging do
    log_file = Path.join(File.cwd!(), "hive.log")

    :logger.add_handler(:hive_file, :logger_std_h, %{
      config: %{file: String.to_charlist(log_file)},
      formatter:
        {:logger_formatter,
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
