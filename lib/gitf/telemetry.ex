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
    [:gitf, :model, :downgraded],
    [:gitf, :conflict, :prevented],
    [:gitf, :drift, :base_captured],
    [:gitf, :drift, :detected],
    [:gitf, :drift, :state_changed],
    [:gitf, :drift, :auto_rebased],
    [:gitf, :drift, :auto_rebase_skipped],
    [:gitf, :drift, :auto_rebase_failed],
    [:gitf, :rollback, :reverted],
    [:gitf, :rollback, :revert_failed],
    [:gitf, :rollback, :revert_skipped],
    [:gitf, :rollback, :revert_pushed]
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

  @doc """
  Wraps a function in a telemetry span for automatic timing.

  Emits `event ++ [:start]` before execution and `event ++ [:stop]`
  (or `event ++ [:exception]`) after, with duration measurements.
  Consistent with `emit/3` — use this instead of raw `:telemetry.span`.
  """
  @spec span(list(atom()), map(), (-> {term(), map()})) :: term()
  def span(event, metadata \\ %{}, fun) do
    :telemetry.span(event, metadata, fun)
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
    {:ghost_spawned, Map.get(meta, :ghost_id, "unknown"), measurements,
     %{op_id: meta[:op_id], mission_id: meta[:mission_id]}}
  end

  defp map_event([:gitf, :ghost, :completed], measurements, meta) do
    {:ghost_completed, Map.get(meta, :ghost_id, "unknown"), measurements,
     %{op_id: meta[:op_id], mission_id: meta[:mission_id]}}
  end

  defp map_event([:gitf, :ghost, :failed], measurements, meta) do
    {:ghost_failed, Map.get(meta, :ghost_id, "unknown"),
     Map.merge(measurements, %{error: meta[:error]}),
     %{op_id: meta[:op_id], mission_id: meta[:mission_id]}}
  end

  defp map_event([:gitf, :ghost, :spawn_failed], measurements, meta) do
    {:ghost_failed, Map.get(meta, :ghost_id, "unknown"),
     Map.merge(measurements, %{step: meta[:step], reason: meta[:reason]}),
     %{op_id: meta[:op_id], sector_id: meta[:sector_id]}}
  end

  defp map_event([:gitf, :ghost, :provision_failed], measurements, meta) do
    {:ghost_failed, Map.get(meta, :ghost_id, "unknown"),
     Map.merge(measurements, %{step: meta[:step], reason: meta[:reason]}), %{op_id: meta[:op_id]}}
  end

  defp map_event([:gitf, :op, :started], measurements, meta) do
    {:job_transition, Map.get(meta, :op_id, "unknown"),
     Map.merge(measurements, %{action: :start}), %{mission_id: meta[:mission_id]}}
  end

  defp map_event([:gitf, :op, :completed], measurements, meta) do
    {:job_transition, Map.get(meta, :op_id, "unknown"),
     Map.merge(measurements, %{action: :complete}), %{mission_id: meta[:mission_id]}}
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
     Map.merge(measurements, %{step: meta[:step], reason: meta[:reason]}), %{op_id: meta[:op_id]}}
  end

  defp map_event([:gitf, :phase, :spawn_failed], measurements, meta) do
    {:ghost_failed, Map.get(meta, :mission_id, "unknown"),
     Map.merge(measurements, %{phase: meta[:phase], reason: meta[:reason]}),
     %{mission_id: meta[:mission_id], op_id: meta[:op_id]}}
  end

  defp map_event([:gitf, :alert, :raised], measurements, meta) do
    {:error, Map.get(meta, :type, "alert") |> to_string(),
     Map.merge(measurements, %{message: meta[:message]}), %{}}
  end

  defp map_event([:gitf, :sync, :crashed], measurements, meta) do
    {:merge_failed, Map.get(meta, :op_id, "unknown"),
     Map.merge(measurements, %{reason: meta[:reason], failure_type: :crash}),
     %{op_id: meta[:op_id]}}
  end

  defp map_event([:gitf, :sync, :timeout], measurements, meta) do
    {:merge_failed, Map.get(meta, :op_id, "unknown"),
     Map.merge(measurements, %{timeout_seconds: meta[:timeout_seconds], failure_type: :timeout}),
     %{op_id: meta[:op_id]}}
  end

  defp map_event([:gitf, :sync, :exhausted], measurements, meta) do
    {:merge_failed, Map.get(meta, :op_id, "unknown"),
     Map.merge(measurements, %{failure_type: :exhausted}), %{op_id: meta[:op_id]}}
  end

  defp map_event([:gitf, :sync, :tier_failed], measurements, meta) do
    {:merge_failed, Map.get(meta, :op_id, "unknown"),
     Map.merge(measurements, %{tier: meta[:tier], failure_type: :tier_failed}),
     %{op_id: meta[:op_id]}}
  end

  defp map_event([:gitf, :store, :data_loss], measurements, meta) do
    {:error, "store", Map.merge(measurements, %{event: :data_loss, message: meta[:message]}), %{}}
  end

  defp map_event([:gitf, :store, :write_error], measurements, meta) do
    {:error, "store", Map.merge(measurements, %{event: :write_error, message: meta[:message]}),
     %{}}
  end

  defp map_event([:gitf, :model, :downgraded], measurements, meta) do
    {:error, Map.get(meta, :ghost_id, "unknown"),
     Map.merge(measurements, %{event: :model_downgraded, from: meta[:from], to: meta[:to]}),
     %{ghost_id: meta[:ghost_id]}}
  end

  # Non-persisted events (high-frequency or informational-only)
  defp map_event(_, _, _), do: nil

  # -- OpenTelemetry span helpers --------------------------------------------
  #
  # Gracefully degrade to no-ops if OpenTelemetry is not loaded.
  # This allows the codebase to compile and run without OTel deps
  # in environments that don't need tracing (e.g., escript builds).

  @otel_tracer_name :gitf

  defp get_tracer, do: :opentelemetry.get_tracer(@otel_tracer_name)

  @doc "Start a root span for a mission pipeline execution."
  def start_mission_span(mission_id, goal) do
    if otel_available?() do
      :otel_tracer.start_span(get_tracer(), "gitf.mission", %{
        attributes: [
          {"mission.id", mission_id},
          {"mission.goal", String.slice(goal || "", 0, 200)}
        ]
      })
      |> :otel_tracer.set_current_span()
    end

    :ok
  end

  @doc "Start a child span for a pipeline phase."
  def start_phase_span(phase, mission_id) do
    if otel_available?() do
      :otel_tracer.start_span(get_tracer(), "gitf.phase.#{phase}", %{
        attributes: [{"phase.name", phase}, {"mission.id", mission_id}]
      })
      |> :otel_tracer.set_current_span()
    end

    :ok
  end

  @doc "Start a child span for a ghost worker execution."
  def start_ghost_span(ghost_id, op_id, mission_id) do
    if otel_available?() do
      :otel_tracer.start_span(get_tracer(), "gitf.ghost", %{
        attributes: [
          {"ghost.id", ghost_id},
          {"op.id", op_id || ""},
          {"mission.id", mission_id || ""}
        ]
      })
      |> :otel_tracer.set_current_span()
    end

    :ok
  end

  @doc "End the current active span."
  def end_current_span do
    if otel_available?() do
      :otel_span.end_span(:otel_tracer.current_span_ctx())
    end

    :ok
  end

  @doc "Mark the current span as errored with a reason."
  def set_span_error(reason) do
    if otel_available?() do
      ctx = :otel_tracer.current_span_ctx()
      :otel_span.set_status(ctx, :error, to_string(reason))
    end

    :ok
  end

  @doc "Extract current trace context for embedding in EventStore records."
  @spec current_trace_context() :: %{trace_id: String.t() | nil, span_id: String.t() | nil}
  def current_trace_context do
    if otel_available?() do
      ctx = :otel_tracer.current_span_ctx()

      case ctx do
        :undefined ->
          %{trace_id: nil, span_id: nil}

        _ ->
          trace_id = :otel_span.trace_id(ctx)
          span_id = :otel_span.span_id(ctx)

          %{
            trace_id: if(trace_id != 0, do: Integer.to_string(trace_id, 16), else: nil),
            span_id: if(span_id != 0, do: Integer.to_string(span_id, 16), else: nil)
          }
      end
    else
      %{trace_id: nil, span_id: nil}
    end
  rescue
    _ -> %{trace_id: nil, span_id: nil}
  end

  defp otel_available? do
    Code.ensure_loaded?(:opentelemetry)
  end
end
