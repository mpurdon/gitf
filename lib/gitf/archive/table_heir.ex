defmodule GiTF.Archive.TableHeir do
  @moduledoc """
  Long-lived ETS heir process for Archive tables.

  Holds references to per-collection and index ETS tables so that, if the
  Archive GenServer crashes, every table survives and can be handed back
  on restart.

  Archive passes this process' PID as the `:heir` option when calling
  `:ets.new/2`. On `{:'ETS-TRANSFER', table, _from, _data}`, this process
  becomes the temporary owner. When the new Archive comes up it calls
  `claim/1` or `claim_all/0` to receive ownership back.
  """

  use GenServer
  require Logger

  @name __MODULE__

  defstruct tables: MapSet.new()

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: @name)
  end

  @doc "Returns this process' PID so Archive can pass it as the ETS `:heir`."
  @spec pid() :: pid() | nil
  def pid, do: Process.whereis(@name)

  @doc "Tell the heir to track `table_name`."
  @spec register(atom()) :: :ok
  def register(table_name) do
    case Process.whereis(@name) do
      nil -> :ok
      pid -> GenServer.call(pid, {:register, table_name})
    end
  end

  @doc "Stop tracking `table_name`."
  @spec unregister(atom()) :: :ok
  def unregister(table_name) do
    case Process.whereis(@name) do
      nil -> :ok
      pid -> GenServer.call(pid, {:unregister, table_name})
    end
  end

  @doc """
  Called by Archive at init time. If the heir currently owns `table`,
  give it back to the caller. Returns `:ok` or `{:error, :not_held}`.
  """
  @spec claim(atom()) :: :ok | {:error, :not_held}
  def claim(table) do
    case Process.whereis(@name) do
      nil -> :ok
      pid -> GenServer.call(pid, {:claim, table, self()})
    end
  end

  @doc "Claim all tables the heir is currently holding back to the caller."
  @spec claim_all() :: :ok
  def claim_all do
    case Process.whereis(@name) do
      nil -> :ok
      pid -> GenServer.call(pid, {:claim_all, self()})
    end
  end

  @doc "Returns the set of currently tracked tables."
  @spec registered_tables() :: MapSet.t()
  def registered_tables do
    case Process.whereis(@name) do
      nil -> MapSet.new()
      pid -> GenServer.call(pid, :registered_tables)
    end
  end

  # -- Callbacks ---------------------------------------------------------------

  @impl true
  def init(:ok), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:register, table_name}, _from, state) do
    {:reply, :ok, %{state | tables: MapSet.put(state.tables, table_name)}}
  end

  def handle_call({:unregister, table_name}, _from, state) do
    {:reply, :ok, %{state | tables: MapSet.delete(state.tables, table_name)}}
  end

  def handle_call({:claim, table, new_owner}, _from, state) do
    if MapSet.member?(state.tables, table) do
      case :ets.info(table, :owner) do
        owner when owner == self() ->
          :ets.give_away(table, new_owner, :reclaimed)
          {:reply, :ok, %{state | tables: MapSet.delete(state.tables, table)}}

        _other ->
          {:reply, {:error, :not_held}, state}
      end
    else
      # Not tracked — try legacy ownership check for backward compat
      case :ets.info(table, :owner) do
        :undefined ->
          {:reply, :ok, state}

        owner when owner == self() ->
          :ets.give_away(table, new_owner, :reclaimed)
          {:reply, :ok, state}

        _other ->
          {:reply, :ok, state}
      end
    end
  end

  def handle_call({:claim_all, new_owner}, _from, state) do
    for table <- state.tables do
      case :ets.info(table, :owner) do
        owner when owner == self() ->
          :ets.give_away(table, new_owner, :reclaimed)

        _ ->
          :ok
      end
    end

    {:reply, :ok, %{state | tables: MapSet.new()}}
  end

  def handle_call(:registered_tables, _from, state) do
    {:reply, state.tables, state}
  end

  @impl true
  def handle_info({:"ETS-TRANSFER", table, _from_pid, _data}, state) do
    Logger.warning(
      "TableHeir received ETS-TRANSFER for #{inspect(table)} — holding until restart"
    )

    {:noreply, %{state | tables: MapSet.put(state.tables, table)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
