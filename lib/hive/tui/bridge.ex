defmodule Hive.TUI.Bridge do
  @moduledoc """
  Connects TUI <-> Hive core.

  Subscribes to PubSub topics, converts waggles to TUI messages.
  Forwards user input via the intent event bus.
  Queries Store for state snapshots.

  ## Intent Event Bus

  Instead of broadcasting raw text on `"queen:input"`, the Bridge publishes
  structured intent events on `"hive:intent"`. Both TUI and future Raylib
  clients publish to the same topic:

      {:intent, :user_input, %{text: "..."}}
      {:intent, :move, %{x: 0, y: 1}}
      {:intent, :interact, %{target: "bee-123"}}
  """

  @topics [
    "waggle:queen",
    "hive:progress",
    "hive:system",
    "hive:view_model",
    "plugins:loaded",
    "plugins:unloaded"
  ]

  @intent_topic "hive:intent"

  @doc "The PubSub topic for intent events."
  @spec intent_topic() :: String.t()
  def intent_topic, do: @intent_topic

  @doc "Subscribe to all relevant PubSub topics."
  @spec subscribe() :: :ok
  def subscribe do
    for topic <- @topics do
      Phoenix.PubSub.subscribe(Hive.PubSub, topic)
    end

    :ok
  end

  @doc "Unsubscribe from all topics."
  @spec unsubscribe() :: :ok
  def unsubscribe do
    for topic <- @topics do
      Phoenix.PubSub.unsubscribe(Hive.PubSub, topic)
    end

    :ok
  end

  @doc """
  Send user input text to the Queen via the intent event bus.

  Also broadcasts on `"queen:input"` for backwards compatibility.
  """
  @spec send_to_queen(String.t()) :: :ok
  def send_to_queen(text) do
    # New: structured intent event
    publish_intent(:user_input, %{text: text})
    # Backwards-compatible: raw broadcast
    Phoenix.PubSub.broadcast(Hive.PubSub, "queen:input", {:user_input, text})
    :ok
  end

  @doc """
  Publish a structured intent event.

  Both TUI and Raylib clients can call this to send intents
  to the Queen/simulation GenServer.
  """
  @spec publish_intent(atom(), map()) :: :ok
  def publish_intent(action, payload \\ %{}) when is_atom(action) do
    Phoenix.PubSub.broadcast(Hive.PubSub, @intent_topic, {:intent, action, payload})
    :ok
  rescue
    _ -> :ok
  end

  @doc "Subscribe to intent events."
  @spec subscribe_intents() :: :ok
  def subscribe_intents do
    Phoenix.PubSub.subscribe(Hive.PubSub, @intent_topic)
  end

  @doc "Get a snapshot of current hive state for display."
  @spec state_snapshot() :: map()
  def state_snapshot do
    %{
      bees: list_bees(),
      quests: list_quests(),
      jobs: list_jobs(),
      progress: list_progress()
    }
  end

  @doc "Lists all bees with their current status."
  @spec list_bees() :: [map()]
  def list_bees do
    Hive.Bees.list()
  rescue
    _ -> []
  end

  @doc "Lists all quests."
  @spec list_quests() :: [map()]
  def list_quests do
    Hive.Quests.list()
  rescue
    _ -> []
  end

  @doc "Lists all jobs."
  @spec list_jobs() :: [map()]
  def list_jobs do
    Hive.Jobs.list()
  rescue
    _ -> []
  end

  @doc "Lists current bee progress entries."
  @spec list_progress() :: [map()]
  def list_progress do
    Hive.Progress.all()
  rescue
    _ -> []
  end
end
