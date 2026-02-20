defmodule Hive.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    setup_file_logging()
    Hive.Progress.init()
    Hive.CircuitBreaker.init()
    Hive.Observability.Metrics.init()
    Hive.Telemetry.attach_default_handlers()
    Hive.Observability.Metrics.attach_handlers()

    children = [
      # PubSub MUST be first — everything else depends on it
      {Phoenix.PubSub, name: Hive.PubSub},
      {Registry, keys: :unique, name: Hive.Registry},
      {Hive.CombSupervisor, []},
      {Hive.Plugin.MCPSupervisor, []},
      {Hive.Plugin.ChannelSupervisor, []},
      {Hive.Plugin.Manager, []},
      # ViewModel starts after PubSub; subscribes in handle_continue
      {Hive.ViewModel, []},
      {Hive.Shutdown, []}
    ]

    opts = [strategy: :one_for_one, name: Hive.Supervisor]
    Supervisor.start_link(children, opts)
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
