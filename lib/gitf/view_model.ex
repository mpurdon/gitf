defmodule GiTF.ViewModel do
  @moduledoc """
  GenServer that maintains an authoritative "world state" for rendering.

  Subscribes to all relevant PubSub topics, merges incoming events into
  a single state struct, and publishes immutable snapshots to
  `"section:view_model"` on every state change.

  Also stores the latest snapshot in `:persistent_term` for poll-based
  access — a Raylib NIF can read without PubSub subscription.

  ## Topics consumed

      "link:major"    — link_msg events
      "section:progress"   — ghost progress updates
      "section:system"     — system events
      "section:intent"     — intent events (for tracking)

  ## Topic published

      "section:view_model" — `{:view_model, snapshot}` on each state change
  """

  use GenServer
  require Logger

  @name __MODULE__
  @pubsub GiTF.PubSub
  @publish_topic "section:view_model"
  @persistent_key {__MODULE__, :latest}

  @subscribe_topics [
    "link:major",
    "section:progress",
    "section:system",
    "section:intent"
  ]

  # -- Client API ------------------------------------------------------------

  @doc "Starts the ViewModel GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Returns the latest view model snapshot."
  @spec snapshot() :: map()
  def snapshot do
    :persistent_term.get(@persistent_key, empty_snapshot())
  end

  @doc "Returns the PubSub topic where snapshots are published."
  @spec topic() :: String.t()
  def topic, do: @publish_topic

  # -- GenServer callbacks ---------------------------------------------------

  @impl true
  def init(_opts) do
    # Subscribe in handle_continue to avoid racing PubSub boot
    {:ok, empty_snapshot(), {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state) do
    for topic <- @subscribe_topics do
      Phoenix.PubSub.subscribe(@pubsub, topic)
    end

    # Warm the snapshot from current store state
    state = refresh_from_store(state)
    publish(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:link_received, link_msg}, state) do
    links = [summarize_link(link_msg) | state.recent_links] |> Enum.take(50)
    state = %{state | recent_links: links, updated_at: now()}
    publish(state)
    {:noreply, state}
  end

  def handle_info({:ghost_progress, ghost_id, entry}, state) do
    progress = Map.put(state.ghost_progress, ghost_id, entry)
    state = %{state | ghost_progress: progress, updated_at: now()}
    publish(state)
    {:noreply, state}
  end

  def handle_info({:intent, action, payload}, state) do
    intent = %{action: action, payload: payload, at: now()}
    intents = [intent | state.recent_intents] |> Enum.take(20)
    state = %{state | recent_intents: intents, updated_at: now()}
    publish(state)
    {:noreply, state}
  end

  def handle_info(:refresh, state) do
    state = refresh_from_store(state)
    publish(state)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # -- Private ---------------------------------------------------------------

  defp empty_snapshot do
    %{
      ghosts: [],
      missions: [],
      ops: [],
      ghost_progress: %{},
      recent_links: [],
      recent_intents: [],
      costs: %{total: 0, count: 0},
      updated_at: now()
    }
  end

  defp refresh_from_store(state) do
    %{
      state
      | ghosts: safe_list(:ghosts),
        missions: safe_list(:missions),
        ops: safe_list(:ops),
        costs: safe_costs(),
        updated_at: now()
    }
  end

  defp safe_list(collection) do
    GiTF.Archive.all(collection)
  rescue
    _ -> []
  end

  defp safe_costs do
    costs = GiTF.Archive.all(:costs)
    %{total: Enum.sum(Enum.map(costs, &(&1.total_cost_usd || 0))), count: length(costs)}
  rescue
    _ -> %{total: 0, count: 0}
  end

  defp summarize_link(link_msg) do
    %{
      from: link_msg.from,
      to: link_msg.to,
      subject: link_msg.subject,
      at: link_msg[:inserted_at] || now()
    }
  end

  defp publish(state) do
    # Archive for poll-based access (Raylib NIF)
    :persistent_term.put(@persistent_key, state)

    # Broadcast for subscription-based access
    Phoenix.PubSub.broadcast(@pubsub, @publish_topic, {:view_model, state})
  rescue
    _ -> :ok
  end

  defp now, do: System.monotonic_time(:millisecond)
end
