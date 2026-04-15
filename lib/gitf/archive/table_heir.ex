defmodule GiTF.Archive.TableHeir do
  @moduledoc """
  Long-lived ETS heir process for the Archive read cache.

  Exists solely to hold a reference to the `:gitf_store_cache` ETS table so
  that, if the Archive GenServer crashes, the table survives and can be
  handed back to the new Archive process on restart.

  Archive passes this process' PID as the `:heir` when calling `:ets.new/2`.
  On `{'ETS-TRANSFER', table, _from, _data}`, this process becomes the
  temporary owner. When the new Archive comes up, it calls `claim/1` to
  receive ownership back.
  """

  use GenServer
  require Logger

  @name __MODULE__

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: @name)
  end

  @doc "Returns this process' PID so Archive can pass it as the ETS `:heir`."
  @spec pid() :: pid() | nil
  def pid, do: Process.whereis(@name)

  @doc """
  Called by Archive at init time. If the heir currently owns `table`,
  give it back to the caller. Returns `:ok` either way.
  """
  @spec claim(atom()) :: :ok
  def claim(table) do
    case Process.whereis(@name) do
      nil -> :ok
      pid -> GenServer.call(pid, {:claim, table, self()})
    end
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:claim, table, new_owner}, _from, state) do
    case :ets.info(table, :owner) do
      :undefined ->
        {:reply, :ok, state}

      owner when owner == self() ->
        :ets.give_away(table, new_owner, :transfer)
        {:reply, :ok, state}

      _other ->
        # Somebody else owns it (e.g. first-ever boot, Archive owns it).
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:"ETS-TRANSFER", table, _from_pid, _data}, state) do
    Logger.warning(
      "TableHeir received ETS-TRANSFER for #{inspect(table)} — Archive crashed, holding until restart"
    )

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
