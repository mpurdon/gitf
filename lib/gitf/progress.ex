defmodule GiTF.Progress do
  @moduledoc """
  Real-time progress tracking for active ghosts via ETS.

  Stores the latest activity for each ghost (tool use, assistant message, etc.)
  and broadcasts updates via PubSub. Pure context module backed by ETS.
  """

  @table :gitf_progress
  @pubsub_topic "section:progress"

  @doc "Creates the ETS table. Called once from Application.start/2."
  @spec init() :: :ok
  def init do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Updates progress data for a ghost."
  @spec update(String.t(), map()) :: :ok
  def update(ghost_id, data) when is_binary(ghost_id) and is_map(data) do
    entry = Map.merge(data, %{ghost_id: ghost_id, updated_at: System.monotonic_time(:millisecond)})
    :ets.insert(@table, {ghost_id, entry})

    Phoenix.PubSub.broadcast(GiTF.PubSub, @pubsub_topic, {:bee_progress, ghost_id, entry})
    :ok
  rescue
    e in ArgumentError ->
      _ = e
      :ok

    e ->
      require Logger
      Logger.error("Progress broadcast failed for #{ghost_id}: #{Exception.message(e)}")
      :ok
  end

  @doc "Returns current progress for a ghost, or nil."
  @spec get(String.t()) :: map() | nil
  def get(ghost_id) do
    case :ets.lookup(@table, ghost_id) do
      [{_key, data}] -> data
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Returns all current progress entries."
  @spec all() :: [map()]
  def all do
    :ets.tab2list(@table)
    |> Enum.map(fn {_key, data} -> data end)
  rescue
    ArgumentError -> []
  end

  @doc "Clears progress for a ghost (when it finishes)."
  @spec clear(String.t()) :: :ok
  def clear(ghost_id) do
    :ets.delete(@table, ghost_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Returns the PubSub topic for progress updates."
  @spec topic() :: String.t()
  def topic, do: @pubsub_topic
end
