defmodule GiTF.TestDriver.Recorder do
  @moduledoc """
  GenServer that captures all system activity into an ordered timeline.

  Attaches to:
  - All `GiTF.Telemetry.events()` via `:telemetry.attach_many/4`
  - PubSub topics: `waggle:major`, `section:progress`, `section:costs`, `section:system`
  - Store polling every 200ms, diffing snapshots for changes

  The timeline is a list of entries ordered by timestamp:

      %{type: :telemetry | :pubsub | :store, event: term(), data: map(), at_us: integer()}

  """

  use GenServer

  @pubsub_topics ["link:major", "section:progress", "section:costs", "section:system"]
  @poll_interval_ms 200

  # -- Client API --------------------------------------------------------------

  @doc "Starts the recorder. Call once per scenario."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Stops the recorder and detaches telemetry handlers."
  @spec stop() :: :ok
  def stop do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.stop(pid, :normal)

      nil ->
        :ok
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Returns the full ordered timeline."
  @spec timeline() :: [map()]
  def timeline do
    GenServer.call(__MODULE__, :timeline)
  end

  @doc """
  Returns filtered timeline entries.

  ## Options

    * `:type` - filter by entry type (`:telemetry`, `:pubsub`, `:store`)
    * `:event` - filter by event name (telemetry event list or PubSub message type)
    * `:metadata` - map of metadata fields to match

  """
  @spec events(keyword()) :: [map()]
  def events(opts \\ []) do
    GenServer.call(__MODULE__, {:events, opts})
  end

  @doc "Clears the timeline. Useful between sub-steps in a scenario."
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # -- GenServer callbacks -----------------------------------------------------

  @impl true
  def init(_opts) do
    handler_id = "section-test-recorder-#{:erlang.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      GiTF.Telemetry.events(),
      &__MODULE__.handle_telemetry_event/4,
      %{recorder: self()}
    )

    Enum.each(@pubsub_topics, fn topic ->
      Phoenix.PubSub.subscribe(GiTF.PubSub, topic)
    end)

    # Take initial store snapshot
    snapshot = take_store_snapshot()

    # Start polling
    Process.send_after(self(), :poll_store, @poll_interval_ms)

    state = %{
      handler_id: handler_id,
      timeline: [],
      store_snapshot: snapshot
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:timeline, _from, state) do
    sorted = Enum.sort_by(state.timeline, & &1.at_us)
    {:reply, sorted, state}
  end

  def handle_call({:events, opts}, _from, state) do
    filtered =
      state.timeline
      |> Enum.sort_by(& &1.at_us)
      |> apply_filters(opts)

    {:reply, filtered, state}
  end

  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | timeline: []}}
  end

  @impl true
  def handle_info({:telemetry_event, event, measurements, metadata}, state) do
    entry = %{
      type: :telemetry,
      event: event,
      data: %{measurements: measurements, metadata: metadata},
      at_us: System.monotonic_time(:microsecond)
    }

    {:noreply, %{state | timeline: [entry | state.timeline]}}
  end

  def handle_info(:poll_store, state) do
    {entries, new_snapshot} =
      try do
        new_snapshot = take_store_snapshot()
        changes = diff_snapshots(state.store_snapshot, new_snapshot)

        entries =
          Enum.map(changes, fn change ->
            %{
              type: :store,
              event: change.action,
              data: change,
              at_us: System.monotonic_time(:microsecond)
            }
          end)

        {entries, new_snapshot}
      rescue
        _ -> {[], state.store_snapshot}
      end

    Process.send_after(self(), :poll_store, @poll_interval_ms)

    {:noreply, %{state | timeline: entries ++ state.timeline, store_snapshot: new_snapshot}}
  end

  # PubSub messages
  def handle_info({:waggle_received, waggle}, state) do
    entry = %{
      type: :pubsub,
      event: :waggle_received,
      data: waggle,
      at_us: System.monotonic_time(:microsecond)
    }

    {:noreply, %{state | timeline: [entry | state.timeline]}}
  end

  def handle_info({:cost_recorded, cost}, state) do
    entry = %{
      type: :pubsub,
      event: :cost_recorded,
      data: cost,
      at_us: System.monotonic_time(:microsecond)
    }

    {:noreply, %{state | timeline: [entry | state.timeline]}}
  end

  def handle_info({:bee_progress, ghost_id, data}, state) do
    entry = %{
      type: :pubsub,
      event: :bee_progress,
      data: Map.put(data, :ghost_id, ghost_id),
      at_us: System.monotonic_time(:microsecond)
    }

    {:noreply, %{state | timeline: [entry | state.timeline]}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(state.handler_id)
    :ok
  end

  # -- Telemetry handler (called in the emitting process) ----------------------

  @doc false
  def handle_telemetry_event(event, measurements, metadata, %{recorder: pid}) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end

  # -- Private: Store snapshotting ---------------------------------------------

  defp take_store_snapshot do
    collections = [:quests, :jobs, :ghosts, :waggles, :costs, :cells, :combs]

    Map.new(collections, fn col ->
      records =
        GiTF.Store.all(col)
        |> Map.new(fn r -> {r.id, r} end)

      {col, records}
    end)
  rescue
    _ -> %{}
  end

  defp diff_snapshots(old, new) do
    collections = Map.keys(new) ++ Map.keys(old)

    collections
    |> Enum.uniq()
    |> Enum.flat_map(fn col ->
      old_col = Map.get(old, col, %{})
      new_col = Map.get(new, col, %{})

      inserts =
        for {id, record} <- new_col, not Map.has_key?(old_col, id) do
          %{action: :insert, collection: col, id: id, record: record}
        end

      deletes =
        for {id, _record} <- old_col, not Map.has_key?(new_col, id) do
          %{action: :delete, collection: col, id: id, record: nil}
        end

      updates =
        for {id, new_record} <- new_col,
            Map.has_key?(old_col, id),
            old_col[id] != new_record do
          %{action: :update, collection: col, id: id, record: new_record, old: old_col[id]}
        end

      inserts ++ deletes ++ updates
    end)
  end

  # -- Private: Filtering ------------------------------------------------------

  defp apply_filters(entries, opts) do
    entries
    |> filter_by_type(opts[:type])
    |> filter_by_event(opts[:event])
    |> filter_by_metadata(opts[:metadata])
  end

  defp filter_by_type(entries, nil), do: entries
  defp filter_by_type(entries, type), do: Enum.filter(entries, &(&1.type == type))

  defp filter_by_event(entries, nil), do: entries

  defp filter_by_event(entries, event) when is_list(event) do
    Enum.filter(entries, &(&1.event == event))
  end

  defp filter_by_event(entries, event) when is_atom(event) do
    Enum.filter(entries, &(&1.event == event))
  end

  defp filter_by_metadata(entries, nil), do: entries

  defp filter_by_metadata(entries, meta) when is_map(meta) do
    Enum.filter(entries, fn entry ->
      data = entry.data

      Enum.all?(meta, fn {k, v} ->
        get_nested(data, k) == v
      end)
    end)
  end

  defp get_nested(%{metadata: metadata}, key) when is_map(metadata) do
    Map.get(metadata, key)
  end

  defp get_nested(data, key) when is_map(data) do
    Map.get(data, key)
  end

  defp get_nested(_, _), do: nil
end
