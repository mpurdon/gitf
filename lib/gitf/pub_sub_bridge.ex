defmodule GiTF.PubSubBridge do
  @moduledoc """
  Bridges internal Telemetry events to GiTF.PubSub for external monitoring.

  This allows external systems (Dashboards, CLIs, LiveViews) to subscribe 
  to the "section:monitor" topic and receive real-time updates about:
  - Ghost lifecycle (spawn, complete, fail)
  - Job progress
  - Quest updates
  - Token usage
  """

  use GenServer
  require Logger

  @topic "section:monitor"

  # -- Client API --------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Subscribe to the section monitoring topic.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(GiTF.PubSub, @topic)
  end

  # -- GenServer callbacks -----------------------------------------------------

  @impl true
  def init(_opts) do
    # Attach to all GiTF telemetry events
    events = GiTF.Telemetry.events()

    :telemetry.attach_many(
      "section-pubsub-bridge",
      events,
      &__MODULE__.handle_event/4,
      %{}
    )

    Logger.info("PubSubBridge started. Broadcasting to #{@topic}")
    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach("section-pubsub-bridge")
    :ok
  end

  @doc false
  def handle_event(event_name, measurements, metadata, _config) do
    # Convert event parts to a dot-separated string, e.g. "section.ghost.spawned"
    event_string = Enum.join(event_name, ".")

    payload = %{
      event: event_string,
      measurements: measurements,
      metadata: Map.put(metadata, :node, Node.self()),
      timestamp: DateTime.utc_now()
    }

    # Broadcast to the monitor topic (best-effort — must not crash telemetry handler)
    try do
      Phoenix.PubSub.broadcast(
        GiTF.PubSub,
        @topic,
        {:gitf_event, payload}
      )
    rescue
      _ -> :ok
    end
  end
end
