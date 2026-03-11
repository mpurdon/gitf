defmodule GiTF.Web.GameChannel do
  use Phoenix.Channel
  require Logger

  alias GiTF.PubSubBridge

  @doc """
  Authorized clients join "game:control".
  They receive the initial world state immediately.
  """
  @impl true
  def join("game:control", _payload, socket) do
    # Subscribe to internal telemetry bridge to forward events to this socket
    PubSubBridge.subscribe()
    
    # Send initial world dump so the game can bootstrap
    send(self(), :send_initial_state)
    
    {:ok, socket}
  end

  # -- Inbound Commands (Game Client -> GiTF) --------------------------------

  @doc """
  Handles inbound commands from the game client.
  
  Supported commands:
  - `spawn_quest`: Create a new work order.
  - `emergency_stop`: Kill all active ghosts.
  """
  @impl true
  def handle_in("spawn_quest", %{"goal" => goal} = payload, socket) do
    # Default to first comb if not provided (demo mode)
    comb_id = Map.get(payload, "comb_id") || default_comb_id()
    
    case GiTF.Quests.create(%{goal: goal, comb_id: comb_id, source: "game_ui"}) do
      {:ok, quest} ->
        {:reply, {:ok, %{quest_id: quest.id}}, socket}
      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("emergency_stop", _payload, socket) do
    Logger.warning("Emergency Stop received from Game Client")
    
    # Kill active ghosts
    active_ghosts = GiTF.Store.filter(:ghosts, fn b -> b.status == "working" end)
    Enum.each(active_ghosts, fn ghost -> GiTF.Ghosts.stop(ghost.id) end)
    
    {:reply, :ok, socket}
  end

  # -- Outbound Events (GiTF -> Game Client) ---------------------------------

  @doc """
  Forward internal PubSub events to the game client.
  We transform the internal payload into a cleaner "Game Protocol".
  """
  @impl true
  def handle_info({:gitf_event, payload}, socket) do
    # payload is %{event: "section.ghost.spawned", measurements: %{}, metadata: %{...}}
    
    # Simplify for the game client
    game_event = %{
      type: payload.event,
      data: payload.metadata,
      timestamp: DateTime.to_unix(payload.timestamp, :millisecond)
    }
    
    push(socket, "gitf_event", game_event)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:send_initial_state, socket) do
    # Snapshot of the world
    state = %{
      quests: GiTF.Store.all(:quests),
      ghosts: GiTF.Store.all(:ghosts),
      combs: GiTF.Store.all(:combs)
    }
    
    push(socket, "world_state", state)
    {:noreply, socket}
  end
  
  defp default_comb_id do
    case GiTF.Comb.list() do
      [first | _] -> first.id
      _ -> nil
    end
  end
end
