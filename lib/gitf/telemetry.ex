defmodule GiTF.Telemetry do
  @moduledoc """
  Defines all GiTF telemetry events and attaches default handlers.

  Events emitted throughout the system:

    [:gitf, :ghost, :spawned]       - measurements: %{}, metadata: %{ghost_id, job_id, comb_id}
    [:gitf, :ghost, :completed]     - measurements: %{duration_ms}, metadata: %{ghost_id, job_id}
    [:gitf, :ghost, :failed]        - measurements: %{duration_ms}, metadata: %{ghost_id, error}
    [:gitf, :job, :started]       - measurements: %{}, metadata: %{job_id, quest_id}
    [:gitf, :job, :completed]     - measurements: %{}, metadata: %{job_id, quest_id}
    [:gitf, :quest, :created]     - measurements: %{}, metadata: %{quest_id, name}
    [:gitf, :quest, :completed]   - measurements: %{}, metadata: %{quest_id, name}
    [:gitf, :waggle, :sent]       - measurements: %{}, metadata: %{from, to, subject}
    [:gitf, :token, :consumed]    - measurements: %{input, output, cost}, metadata: %{model, ghost_id}
    [:gitf, :plugin, :loaded]     - measurements: %{}, metadata: %{type, name, module}
    [:gitf, :plugin, :unloaded]   - measurements: %{}, metadata: %{type, name}

  Channels subscribe to telemetry events (not PubSub) for notifications.
  This decouples notification routing from internal messaging. Any plugin
  can attach a telemetry handler to observe any system event.

  Each handled event is also persisted to `GiTF.EventStore` for replay
  and audit trail support.
  """

  require Logger

  @events [
    [:gitf, :ghost, :spawned],
    [:gitf, :ghost, :completed],
    [:gitf, :ghost, :failed],
    [:gitf, :ghost, :provision_failed],
    [:gitf, :job, :started],
    [:gitf, :job, :completed],
    [:gitf, :quest, :created],
    [:gitf, :quest, :completed],
    [:gitf, :waggle, :sent],
    [:gitf, :token, :consumed],
    [:gitf, :plugin, :loaded],
    [:gitf, :plugin, :unloaded],
    [:gitf, :alert, :raised],
    [:gitf, :merge, :exhausted],
    [:gitf, :merge, :tier_failed],
    [:gitf, :merge, :crashed],
    [:gitf, :merge, :timeout],
    [:gitf, :health, :checked],
    [:gitf, :store, :data_loss],
    [:gitf, :store, :write_error],
    [:gitf, :model, :downgraded]
  ]

  @doc "Returns all defined telemetry event names."
  @spec events() :: [list(atom())]
  def events, do: @events

  @doc "Attaches the default log handler for all events."
  @spec attach_default_handlers() :: :ok
  def attach_default_handlers do
    :telemetry.attach_many(
      "section-default-logger",
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
        {type, entity_id, data, meta} -> GiTF.EventStore.record(type, entity_id, data, meta)
      end
    rescue
      _ -> :ok
    end
  end

  defp map_event([:gitf, :ghost, :spawned], measurements, meta) do
    {:bee_spawned, Map.get(meta, :ghost_id, "unknown"), measurements,
     %{job_id: meta[:job_id], quest_id: meta[:quest_id]}}
  end

  defp map_event([:gitf, :ghost, :completed], measurements, meta) do
    {:bee_completed, Map.get(meta, :ghost_id, "unknown"), measurements,
     %{job_id: meta[:job_id], quest_id: meta[:quest_id]}}
  end

  defp map_event([:gitf, :ghost, :failed], measurements, meta) do
    {:bee_failed, Map.get(meta, :ghost_id, "unknown"),
     Map.merge(measurements, %{error: meta[:error]}),
     %{job_id: meta[:job_id], quest_id: meta[:quest_id]}}
  end

  defp map_event([:gitf, :job, :started], measurements, meta) do
    {:job_transition, Map.get(meta, :job_id, "unknown"),
     Map.merge(measurements, %{action: :start}),
     %{quest_id: meta[:quest_id]}}
  end

  defp map_event([:gitf, :job, :completed], measurements, meta) do
    {:job_transition, Map.get(meta, :job_id, "unknown"),
     Map.merge(measurements, %{action: :complete}),
     %{quest_id: meta[:quest_id]}}
  end

  defp map_event([:gitf, :quest, :created], measurements, meta) do
    {:quest_created, Map.get(meta, :quest_id, "unknown"),
     Map.merge(measurements, %{name: meta[:name]}), %{}}
  end

  defp map_event([:gitf, :quest, :completed], measurements, meta) do
    {:quest_completed, Map.get(meta, :quest_id, "unknown"),
     Map.merge(measurements, %{name: meta[:name]}), %{}}
  end

  defp map_event(_, _, _), do: nil
end
