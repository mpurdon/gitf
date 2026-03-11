defmodule GiTF.TUI.Bridge do
  @moduledoc """
  Connects TUI <-> GiTF core.

  Subscribes to PubSub topics, converts links to TUI messages.
  Forwards user input via the intent event bus.
  Queries Archive for state snapshots.

  ## Intent Event Bus

  Instead of broadcasting raw text on `"queen:input"`, the Bridge publishes
  structured intent events on `"section:intent"`. Both TUI and future Raylib
  clients publish to the same topic:

      {:intent, :user_input, %{text: "..."}}
      {:intent, :move, %{x: 0, y: 1}}
      {:intent, :interact, %{target: "ghost-123"}}
  """

  @topics [
    "link:major",
    "section:progress",
    "section:system",
    "section:view_model",
    "plugins:loaded",
    "plugins:unloaded"
  ]

  @intent_topic "section:intent"

  @doc "The PubSub topic for intent events."
  @spec intent_topic() :: String.t()
  def intent_topic, do: @intent_topic

  @doc "Subscribe to all relevant PubSub topics."
  @spec subscribe() :: :ok
  def subscribe do
    for topic <- @topics do
      Phoenix.PubSub.subscribe(GiTF.PubSub, topic)
    end

    :ok
  end

  @doc "Unsubscribe from all topics."
  @spec unsubscribe() :: :ok
  def unsubscribe do
    for topic <- @topics do
      Phoenix.PubSub.unsubscribe(GiTF.PubSub, topic)
    end

    :ok
  end

  @doc """
  Send user input text to the Major via the intent event bus.

  Also broadcasts on `"queen:input"` for backwards compatibility.
  """
  @spec send_to_major(String.t()) :: :ok
  def send_to_major(text) do
    # New: structured intent event
    publish_intent(:user_input, %{text: text})
    # Backwards-compatible: raw broadcast
    Phoenix.PubSub.broadcast(GiTF.PubSub, "queen:input", {:user_input, text})
    :ok
  end

  @doc """
  Publish a structured intent event.

  Both TUI and Raylib clients can call this to send intents
  to the Major/simulation GenServer.
  """
  @spec publish_intent(atom(), map()) :: :ok
  def publish_intent(action, payload \\ %{}) when is_atom(action) do
    Phoenix.PubSub.broadcast(GiTF.PubSub, @intent_topic, {:intent, action, payload})
    :ok
  rescue
    _ -> :ok
  end

  @doc "Subscribe to intent events."
  @spec subscribe_intents() :: :ok
  def subscribe_intents do
    Phoenix.PubSub.subscribe(GiTF.PubSub, @intent_topic)
  end

  @doc "Get a snapshot of current section state for display."
  @spec state_snapshot() :: map()
  def state_snapshot do
    %{
      ghosts: list_bees(),
      missions: list_quests(),
      ops: list_jobs(),
      progress: list_progress()
    }
  end

  @doc "Lists all ghosts with their current status."
  @spec list_bees() :: [map()]
  def list_bees do
    GiTF.Ghosts.list()
  rescue
    _ -> []
  end

  @doc "Lists all missions."
  @spec list_quests() :: [map()]
  def list_quests do
    GiTF.Missions.list()
  rescue
    _ -> []
  end

  @doc "Lists all ops."
  @spec list_jobs() :: [map()]
  def list_jobs do
    GiTF.Ops.list()
  rescue
    _ -> []
  end

  @doc "Lists current ghost progress entries."
  @spec list_progress() :: [map()]
  def list_progress do
    GiTF.Progress.all()
  rescue
    _ -> []
  end
end
