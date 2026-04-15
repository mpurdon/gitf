defmodule GiTF.EventStore do
  @moduledoc """
  Persistent event log with replay support.

  A context module (no GenServer) backed by `GiTF.Archive`. Every significant
  action in the system — ghost lifecycle, op transitions, mission milestones —
  is recorded as an immutable event. This provides:

  - **Audit trail**: what happened, when, and to whom.
  - **Replay**: reconstruct entity history from its event stream.
  - **Timeline**: see all activity for a mission across ops, ghosts, and merges.

  All event data passes through `GiTF.Redaction.redact_map/1` before
  persistence to ensure secrets never reach the event log.
  """

  alias GiTF.Archive

  @event_types [
    :ghost_spawned,
    :ghost_completed,
    :ghost_failed,
    :ghost_stopped,
    :job_created,
    :job_transition,
    :job_verified,
    :job_rejected,
    :scout_dispatched,
    :scout_complete,
    :drone_verdict,
    :merge_started,
    :merge_succeeded,
    :merge_failed,
    :quest_created,
    :quest_completed,
    :quest_failed,
    :link_sent,
    :backup,
    :error
  ]

  @collection :events

  # -- Public API ------------------------------------------------------------

  @doc "Returns the list of valid event types."
  @spec event_types() :: [atom()]
  def event_types, do: @event_types

  @doc """
  Records an event. Data is redacted before persistence.

  Returns `{:ok, event}` or `{:error, :invalid_event_type}`.

  ## Examples

      iex> GiTF.EventStore.record(:ghost_spawned, "ghost-abc123", %{model: "sonnet"})
      {:ok, %{type: :ghost_spawned, entity_id: "ghost-abc123", ...}}
  """
  @spec record(atom(), String.t(), map()) :: {:ok, map()} | {:error, :invalid_event_type}
  def record(event_type, entity_id, data) do
    record(event_type, entity_id, data, %{})
  end

  @doc """
  Records an event with metadata for cross-referencing.

  Metadata may include `:mission_id`, `:op_id`, `:ghost_id` to link
  events across entity boundaries.
  """
  @spec record(atom(), String.t(), map(), map()) :: {:ok, map()} | {:error, :invalid_event_type}
  def record(event_type, _entity_id, _data, _metadata) when event_type not in @event_types do
    {:error, :invalid_event_type}
  end

  def record(event_type, entity_id, data, metadata) do
    trace_ctx = GiTF.Telemetry.current_trace_context()

    event = %{
      type: event_type,
      entity_id: entity_id,
      data: GiTF.Redaction.redact_map(data),
      metadata: GiTF.Redaction.redact_map(metadata),
      trace_id: trace_ctx.trace_id,
      span_id: trace_ctx.span_id,
      timestamp: DateTime.utc_now()
    }

    Archive.insert(@collection, event)
  end

  @doc """
  Lists events matching the given filters.

  ## Options

    * `:type` - filter by event type atom
    * `:entity_id` - filter by entity ID string
    * `:since` - `DateTime`, only events after this time
    * `:limit` - max results (default 100)
    * `:mission_id` - filter by metadata mission_id
    * `:op_id` - filter by metadata op_id
    * `:ghost_id` - filter by metadata ghost_id

  Results are sorted by timestamp descending (newest first).
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Archive.all(@collection)
    |> apply_filters(opts)
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
    |> Enum.take(limit)
  end

  @doc """
  Replays all events for a given entity in chronological order.

  ## Options

    * `:since` - `DateTime`, only events after this time
    * `:types` - list of event type atoms to include
  """
  @spec replay(String.t(), keyword()) :: [map()]
  def replay(entity_id, opts \\ []) do
    types = Keyword.get(opts, :types)

    Archive.all(@collection)
    |> Enum.filter(&(&1.entity_id == entity_id))
    |> maybe_filter_since(Keyword.get(opts, :since))
    |> maybe_filter_types(types)
    |> Enum.sort_by(& &1.timestamp, {:asc, DateTime})
    |> Enum.map(&Map.take(&1, [:timestamp, :type, :data]))
  end

  @doc """
  Returns a full chronological timeline for a mission.

  Gathers all events across every entity (ops, ghosts, merges) whose
  metadata `:mission_id` matches the given mission ID.
  """
  @spec timeline(String.t()) :: [map()]
  def timeline(mission_id) do
    Archive.all(@collection)
    |> Enum.filter(fn event ->
      get_in(event, [:metadata, :mission_id]) == mission_id or
        event.entity_id == mission_id
    end)
    |> Enum.sort_by(& &1.timestamp, {:asc, DateTime})
  end

  @doc """
  Returns an enriched timeline for a mission with phase durations and cost data.

  Builds on `timeline/1` by computing how long each phase took and merging
  per-phase cost attribution from `GiTF.Costs.quest_phase_summary/1`.
  """
  @spec enriched_timeline(String.t()) :: map()
  def enriched_timeline(mission_id) do
    events = timeline(mission_id)
    transitions = GiTF.Missions.get_phase_transitions(mission_id)
    phase_costs = GiTF.Costs.quest_phase_summary(mission_id)

    phases = build_phase_durations(transitions)

    phases =
      Enum.map(phases, fn p ->
        cost_data =
          Map.get(phase_costs.by_phase, p.phase, %{cost: 0, input_tokens: 0, output_tokens: 0})

        Map.merge(p, %{
          cost_usd: cost_data.cost,
          tokens: Map.get(cost_data, :input_tokens, 0) + Map.get(cost_data, :output_tokens, 0)
        })
      end)

    %{
      events: events,
      phases: phases,
      phase_costs: phase_costs,
      total_cost: phase_costs.total,
      total_duration_s: total_duration(phases)
    }
  end

  @doc """
  Deletes events older than the specified number of days.

  Returns the count of deleted events.

  ## Options

    * `:days` - cutoff in days (default 30)
  """
  @spec prune(keyword()) :: non_neg_integer()
  def prune(opts \\ []) do
    days = Keyword.get(opts, :days, 30)
    cutoff = DateTime.utc_now() |> DateTime.shift(day: -days)

    to_delete =
      Archive.all(@collection)
      |> Enum.filter(fn event -> DateTime.compare(event.timestamp, cutoff) == :lt end)

    Enum.each(to_delete, fn event -> Archive.delete(@collection, event.id) end)

    length(to_delete)
  end

  @doc """
  Counts events matching the given filters.

  Accepts the same filter options as `list/1` (except `:limit`).
  """
  @spec count(keyword()) :: non_neg_integer()
  def count(opts \\ []) do
    Archive.all(@collection)
    |> apply_filters(opts)
    |> length()
  end

  # -- Private helpers -------------------------------------------------------

  defp apply_filters(events, opts) do
    events
    |> maybe_filter_type(Keyword.get(opts, :type))
    |> maybe_filter_entity(Keyword.get(opts, :entity_id))
    |> maybe_filter_since(Keyword.get(opts, :since))
    |> maybe_filter_metadata(:mission_id, Keyword.get(opts, :mission_id))
    |> maybe_filter_metadata(:op_id, Keyword.get(opts, :op_id))
    |> maybe_filter_metadata(:ghost_id, Keyword.get(opts, :ghost_id))
  end

  defp maybe_filter_type(events, nil), do: events
  defp maybe_filter_type(events, type), do: Enum.filter(events, &(&1.type == type))

  defp maybe_filter_entity(events, nil), do: events
  defp maybe_filter_entity(events, id), do: Enum.filter(events, &(&1.entity_id == id))

  defp maybe_filter_since(events, nil), do: events

  defp maybe_filter_since(events, since) do
    Enum.filter(events, fn event ->
      DateTime.compare(event.timestamp, since) in [:gt, :eq]
    end)
  end

  defp maybe_filter_types(events, nil), do: events
  defp maybe_filter_types(events, types), do: Enum.filter(events, &(&1.type in types))

  defp maybe_filter_metadata(events, _key, nil), do: events

  defp maybe_filter_metadata(events, key, value) do
    Enum.filter(events, fn event ->
      get_in(event, [:metadata, key]) == value
    end)
  end

  # Compute duration per phase from consecutive transition timestamps
  defp build_phase_durations(transitions) do
    # Sort by inserted_at (always a DateTime from Archive) to avoid mixed-type comparison
    sorted =
      transitions
      |> Enum.sort_by(& &1[:inserted_at], {:asc, DateTime})

    sorted
    |> Enum.chunk_every(2, 1)
    |> Enum.map(fn
      [current, next] ->
        started = current[:inserted_at]
        ended = next[:inserted_at]

        duration_s =
          if started && ended, do: DateTime.diff(ended, started, :second), else: nil

        %{
          phase: current[:to_phase] || current[:phase],
          started_at: started,
          ended_at: ended,
          duration_s: duration_s,
          reason: current[:reason]
        }

      [current] ->
        %{
          phase: current[:to_phase] || current[:phase],
          started_at: current[:inserted_at],
          ended_at: nil,
          duration_s: nil,
          reason: current[:reason]
        }
    end)
  end

  defp total_duration(phases) do
    phases
    |> Enum.map(&(&1[:duration_s] || 0))
    |> Enum.sum()
  end
end
