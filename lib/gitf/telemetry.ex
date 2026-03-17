defmodule GiTF.Telemetry do
  @moduledoc """
  Defines all GiTF telemetry events and attaches default handlers.

  Events emitted throughout the system:

    [:gitf, :ghost, :spawned]       - measurements: %{}, metadata: %{ghost_id, op_id, sector_id}
    [:gitf, :ghost, :completed]     - measurements: %{duration_ms}, metadata: %{ghost_id, op_id}
    [:gitf, :ghost, :failed]        - measurements: %{duration_ms}, metadata: %{ghost_id, error}
    [:gitf, :op, :started]       - measurements: %{}, metadata: %{op_id, mission_id}
    [:gitf, :op, :completed]     - measurements: %{}, metadata: %{op_id, mission_id}
    [:gitf, :mission, :created]     - measurements: %{}, metadata: %{mission_id, name}
    [:gitf, :mission, :completed]   - measurements: %{}, metadata: %{mission_id, name}
    [:gitf, :link_msg, :sent]       - measurements: %{}, metadata: %{from, to, subject}
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
    [:gitf, :ghost, :spawn_failed],
    [:gitf, :ghost, :provision_failed],
    [:gitf, :op, :started],
    [:gitf, :op, :completed],
    [:gitf, :mission, :created],
    [:gitf, :mission, :completed],
    [:gitf, :link_msg, :sent],
    [:gitf, :token, :consumed],
    [:gitf, :plugin, :loaded],
    [:gitf, :plugin, :unloaded],
    [:gitf, :tachikoma, :review_failed],
    [:gitf, :phase, :spawn_failed],
    [:gitf, :alert, :raised],
    [:gitf, :sync, :exhausted],
    [:gitf, :sync, :tier_failed],
    [:gitf, :sync, :crashed],
    [:gitf, :sync, :timeout],
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
     %{op_id: meta[:op_id], mission_id: meta[:mission_id]}}
  end

  defp map_event([:gitf, :ghost, :completed], measurements, meta) do
    {:bee_completed, Map.get(meta, :ghost_id, "unknown"), measurements,
     %{op_id: meta[:op_id], mission_id: meta[:mission_id]}}
  end

  defp map_event([:gitf, :ghost, :failed], measurements, meta) do
    {:bee_failed, Map.get(meta, :ghost_id, "unknown"),
     Map.merge(measurements, %{error: meta[:error]}),
     %{op_id: meta[:op_id], mission_id: meta[:mission_id]}}
  end

  defp map_event([:gitf, :ghost, :spawn_failed], measurements, meta) do
    {:bee_failed, Map.get(meta, :ghost_id, "unknown"),
     Map.merge(measurements, %{step: meta[:step], reason: meta[:reason]}),
     %{op_id: meta[:op_id], sector_id: meta[:sector_id]}}
  end

  defp map_event([:gitf, :ghost, :provision_failed], measurements, meta) do
    {:bee_failed, Map.get(meta, :ghost_id, "unknown"),
     Map.merge(measurements, %{step: meta[:step], reason: meta[:reason]}),
     %{op_id: meta[:op_id]}}
  end

  defp map_event([:gitf, :op, :started], measurements, meta) do
    {:job_transition, Map.get(meta, :op_id, "unknown"),
     Map.merge(measurements, %{action: :start}),
     %{mission_id: meta[:mission_id]}}
  end

  defp map_event([:gitf, :op, :completed], measurements, meta) do
    {:job_transition, Map.get(meta, :op_id, "unknown"),
     Map.merge(measurements, %{action: :complete}),
     %{mission_id: meta[:mission_id]}}
  end

  defp map_event([:gitf, :mission, :created], measurements, meta) do
    {:quest_created, Map.get(meta, :mission_id, "unknown"),
     Map.merge(measurements, %{name: meta[:name]}), %{}}
  end

  defp map_event([:gitf, :mission, :completed], measurements, meta) do
    {:quest_completed, Map.get(meta, :mission_id, "unknown"),
     Map.merge(measurements, %{name: meta[:name]}), %{}}
  end

  defp map_event([:gitf, :tachikoma, :review_failed], measurements, meta) do
    {:error, Map.get(meta, :op_id, "tachikoma"),
     Map.merge(measurements, %{step: meta[:step], reason: meta[:reason]}),
     %{op_id: meta[:op_id]}}
  end

  defp map_event([:gitf, :phase, :spawn_failed], measurements, meta) do
    {:bee_failed, Map.get(meta, :mission_id, "unknown"),
     Map.merge(measurements, %{phase: meta[:phase], reason: meta[:reason]}),
     %{mission_id: meta[:mission_id], op_id: meta[:op_id]}}
  end

  defp map_event(_, _, _), do: nil
end
