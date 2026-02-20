defmodule Hive.Telemetry do
  @moduledoc """
  Defines all Hive telemetry events and attaches default handlers.

  Events emitted throughout the system:

    [:hive, :bee, :spawned]       - measurements: %{}, metadata: %{bee_id, job_id, comb_id}
    [:hive, :bee, :completed]     - measurements: %{duration_ms}, metadata: %{bee_id, job_id}
    [:hive, :bee, :failed]        - measurements: %{duration_ms}, metadata: %{bee_id, error}
    [:hive, :job, :started]       - measurements: %{}, metadata: %{job_id, quest_id}
    [:hive, :job, :completed]     - measurements: %{}, metadata: %{job_id, quest_id}
    [:hive, :quest, :created]     - measurements: %{}, metadata: %{quest_id, name}
    [:hive, :quest, :completed]   - measurements: %{}, metadata: %{quest_id, name}
    [:hive, :waggle, :sent]       - measurements: %{}, metadata: %{from, to, subject}
    [:hive, :token, :consumed]    - measurements: %{input, output, cost}, metadata: %{model, bee_id}
    [:hive, :plugin, :loaded]     - measurements: %{}, metadata: %{type, name, module}
    [:hive, :plugin, :unloaded]   - measurements: %{}, metadata: %{type, name}
    [:hive, :council, :applied]   - measurements: %{}, metadata: %{council_id, quest_id, wave_count, expert_count}
    [:hive, :council, :wave_start] - measurements: %{}, metadata: %{council_id, wave, experts, job_id}

  Channels subscribe to telemetry events (not PubSub) for notifications.
  This decouples notification routing from internal messaging. Any plugin
  can attach a telemetry handler to observe any system event.
  """

  require Logger

  @events [
    [:hive, :bee, :spawned],
    [:hive, :bee, :completed],
    [:hive, :bee, :failed],
    [:hive, :job, :started],
    [:hive, :job, :completed],
    [:hive, :quest, :created],
    [:hive, :quest, :completed],
    [:hive, :waggle, :sent],
    [:hive, :token, :consumed],
    [:hive, :plugin, :loaded],
    [:hive, :plugin, :unloaded],
    [:hive, :council, :applied],
    [:hive, :council, :wave_start]
  ]

  @doc "Returns all defined telemetry event names."
  @spec events() :: [list(atom())]
  def events, do: @events

  @doc "Attaches the default log handler for all events."
  @spec attach_default_handlers() :: :ok
  def attach_default_handlers do
    :telemetry.attach_many(
      "hive-default-logger",
      @events,
      &__MODULE__.handle_event/4,
      %{}
    )
  end

  @doc "Emits a telemetry event with measurements and metadata."
  @spec emit(list(atom()), map(), map()) :: :ok
  def emit(event, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute(event, measurements, metadata)
  end

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    event_name = Enum.join(event, ".")

    Logger.debug("#{event_name} #{inspect(measurements)} #{inspect(metadata)}")
  end
end
