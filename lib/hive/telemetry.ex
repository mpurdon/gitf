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

  Channels subscribe to telemetry events (not PubSub) for notifications.
  This decouples notification routing from internal messaging. Any plugin
  can attach a telemetry handler to observe any system event.

  Each handled event is also persisted to `Hive.EventStore` for replay
  and audit trail support.
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
    [:hive, :plugin, :unloaded]
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

    persist_to_event_store(event, measurements, metadata)
  end

  # -- EventStore persistence ------------------------------------------------
  #
  # Maps telemetry events to EventStore event types and persists them.
  # Wrapped in try/rescue so event store failures never crash the handler.

  defp persist_to_event_store(event, measurements, metadata) do
    try do
      case map_event(event, measurements, metadata) do
        nil -> :ok
        {type, entity_id, data, meta} -> Hive.EventStore.record(type, entity_id, data, meta)
      end
    rescue
      _ -> :ok
    end
  end

  defp map_event([:hive, :bee, :spawned], measurements, meta) do
    {:bee_spawned, Map.get(meta, :bee_id, "unknown"), measurements,
     %{job_id: meta[:job_id], quest_id: meta[:quest_id]}}
  end

  defp map_event([:hive, :bee, :completed], measurements, meta) do
    {:bee_completed, Map.get(meta, :bee_id, "unknown"), measurements,
     %{job_id: meta[:job_id], quest_id: meta[:quest_id]}}
  end

  defp map_event([:hive, :bee, :failed], measurements, meta) do
    {:bee_failed, Map.get(meta, :bee_id, "unknown"),
     Map.merge(measurements, %{error: meta[:error]}),
     %{job_id: meta[:job_id], quest_id: meta[:quest_id]}}
  end

  defp map_event([:hive, :job, :started], measurements, meta) do
    {:job_transition, Map.get(meta, :job_id, "unknown"),
     Map.merge(measurements, %{action: :start}),
     %{quest_id: meta[:quest_id]}}
  end

  defp map_event([:hive, :job, :completed], measurements, meta) do
    {:job_transition, Map.get(meta, :job_id, "unknown"),
     Map.merge(measurements, %{action: :complete}),
     %{quest_id: meta[:quest_id]}}
  end

  defp map_event([:hive, :quest, :created], measurements, meta) do
    {:quest_created, Map.get(meta, :quest_id, "unknown"),
     Map.merge(measurements, %{name: meta[:name]}), %{}}
  end

  defp map_event([:hive, :quest, :completed], measurements, meta) do
    {:quest_completed, Map.get(meta, :quest_id, "unknown"),
     Map.merge(measurements, %{name: meta[:name]}), %{}}
  end

  defp map_event(_, _, _), do: nil
end
