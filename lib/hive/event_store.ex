defmodule Hive.EventStore do
  @moduledoc """
  Persistent event log with replay support.

  A context module (no GenServer) backed by `Hive.Store`. Every significant
  action in the system — bee lifecycle, job transitions, quest milestones —
  is recorded as an immutable event. This provides:

  - **Audit trail**: what happened, when, and to whom.
  - **Replay**: reconstruct entity history from its event stream.
  - **Timeline**: see all activity for a quest across jobs, bees, and merges.

  All event data passes through `Hive.Redaction.redact_map/1` before
  persistence to ensure secrets never reach the event log.
  """

  alias Hive.Store

  @event_types [
    :bee_spawned,
    :bee_completed,
    :bee_failed,
    :bee_stopped,
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
    :waggle_sent,
    :checkpoint,
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

      iex> Hive.EventStore.record(:bee_spawned, "bee-abc123", %{model: "sonnet"})
      {:ok, %{type: :bee_spawned, entity_id: "bee-abc123", ...}}
  """
  @spec record(atom(), String.t(), map()) :: {:ok, map()} | {:error, :invalid_event_type}
  def record(event_type, entity_id, data) do
    record(event_type, entity_id, data, %{})
  end

  @doc """
  Records an event with metadata for cross-referencing.

  Metadata may include `:quest_id`, `:job_id`, `:bee_id` to link
  events across entity boundaries.
  """
  @spec record(atom(), String.t(), map(), map()) :: {:ok, map()} | {:error, :invalid_event_type}
  def record(event_type, _entity_id, _data, _metadata) when event_type not in @event_types do
    {:error, :invalid_event_type}
  end

  def record(event_type, entity_id, data, metadata) do
    event = %{
      type: event_type,
      entity_id: entity_id,
      data: Hive.Redaction.redact_map(data),
      metadata: Hive.Redaction.redact_map(metadata),
      timestamp: DateTime.utc_now()
    }

    Store.insert(@collection, event)
  end

  @doc """
  Lists events matching the given filters.

  ## Options

    * `:type` - filter by event type atom
    * `:entity_id` - filter by entity ID string
    * `:since` - `DateTime`, only events after this time
    * `:limit` - max results (default 100)
    * `:quest_id` - filter by metadata quest_id
    * `:job_id` - filter by metadata job_id
    * `:bee_id` - filter by metadata bee_id

  Results are sorted by timestamp descending (newest first).
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Store.all(@collection)
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

    Store.all(@collection)
    |> Enum.filter(&(&1.entity_id == entity_id))
    |> maybe_filter_since(Keyword.get(opts, :since))
    |> maybe_filter_types(types)
    |> Enum.sort_by(& &1.timestamp, {:asc, DateTime})
    |> Enum.map(&Map.take(&1, [:timestamp, :type, :data]))
  end

  @doc """
  Returns a full chronological timeline for a quest.

  Gathers all events across every entity (jobs, bees, merges) whose
  metadata `:quest_id` matches the given quest ID.
  """
  @spec timeline(String.t()) :: [map()]
  def timeline(quest_id) do
    Store.all(@collection)
    |> Enum.filter(fn event ->
      get_in(event, [:metadata, :quest_id]) == quest_id or
        event.entity_id == quest_id
    end)
    |> Enum.sort_by(& &1.timestamp, {:asc, DateTime})
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
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

    to_delete =
      Store.all(@collection)
      |> Enum.filter(fn event -> DateTime.compare(event.timestamp, cutoff) == :lt end)

    Enum.each(to_delete, fn event -> Store.delete(@collection, event.id) end)

    length(to_delete)
  end

  @doc """
  Counts events matching the given filters.

  Accepts the same filter options as `list/1` (except `:limit`).
  """
  @spec count(keyword()) :: non_neg_integer()
  def count(opts \\ []) do
    Store.all(@collection)
    |> apply_filters(opts)
    |> length()
  end

  # -- Private helpers -------------------------------------------------------

  defp apply_filters(events, opts) do
    events
    |> maybe_filter_type(Keyword.get(opts, :type))
    |> maybe_filter_entity(Keyword.get(opts, :entity_id))
    |> maybe_filter_since(Keyword.get(opts, :since))
    |> maybe_filter_metadata(:quest_id, Keyword.get(opts, :quest_id))
    |> maybe_filter_metadata(:job_id, Keyword.get(opts, :job_id))
    |> maybe_filter_metadata(:bee_id, Keyword.get(opts, :bee_id))
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
end
