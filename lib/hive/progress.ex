defmodule Hive.Progress do
  @moduledoc """
  Real-time progress tracking for active bees via ETS.

  Stores the latest activity for each bee (tool use, assistant message, etc.)
  and broadcasts updates via PubSub. Pure context module backed by ETS.
  """

  @table :hive_progress
  @pubsub_topic "hive:progress"

  @doc "Creates the ETS table. Called once from Application.start/2."
  @spec init() :: :ok
  def init do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Updates progress data for a bee."
  @spec update(String.t(), map()) :: :ok
  def update(bee_id, data) when is_binary(bee_id) and is_map(data) do
    entry = Map.merge(data, %{bee_id: bee_id, updated_at: System.monotonic_time(:millisecond)})
    :ets.insert(@table, {bee_id, entry})

    Phoenix.PubSub.broadcast(Hive.PubSub, @pubsub_topic, {:bee_progress, bee_id, entry})
    :ok
  rescue
    e in ArgumentError ->
      _ = e
      :ok

    e ->
      require Logger
      Logger.error("Progress broadcast failed for #{bee_id}: #{Exception.message(e)}")
      :ok
  end

  @doc "Returns current progress for a bee, or nil."
  @spec get(String.t()) :: map() | nil
  def get(bee_id) do
    case :ets.lookup(@table, bee_id) do
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

  @doc "Clears progress for a bee (when it finishes)."
  @spec clear(String.t()) :: :ok
  def clear(bee_id) do
    :ets.delete(@table, bee_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Returns the PubSub topic for progress updates."
  @spec topic() :: String.t()
  def topic, do: @pubsub_topic
end
