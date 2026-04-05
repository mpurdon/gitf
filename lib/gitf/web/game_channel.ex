defmodule GiTF.Web.GameChannel do
  use Phoenix.Channel
  require Logger

  require GiTF.Ghost.Status, as: GhostStatus
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
    # Default to first sector if not provided (demo mode)
    sector_id = Map.get(payload, "sector_id") || default_sector_id()

    case GiTF.Missions.create(%{goal: goal, sector_id: sector_id, source: "game_ui"}) do
      {:ok, mission} ->
        {:reply, {:ok, %{mission_id: mission.id}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("emergency_stop", _payload, socket) do
    Logger.warning("Emergency Stop received from Game Client")

    # Kill active ghosts
    active_ghosts = GiTF.Archive.filter(:ghosts, fn b -> b.status == GhostStatus.working() end)
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
      missions: GiTF.Archive.all(:missions),
      ghosts: GiTF.Archive.all(:ghosts),
      sectors: GiTF.Archive.all(:sectors)
    }

    push(socket, "world_state", state)
    {:noreply, socket}
  end

  defp default_sector_id do
    case GiTF.Sector.list() do
      [first | _] -> first.id
      _ -> nil
    end
  end
end
