defmodule GiTF.Archive.Writer do
  @moduledoc """
  Per-collection write serializer for `GiTF.Archive`.

  Runs under a `PartitionSupervisor` keyed by collection, so:

    * writes to the **same** collection always route to the same partition and
      are therefore serialized — this gives read-modify-write (`update`) and
      secondary-index diffs their atomicity without any lock, and
    * writes to **different** collections usually land on different partitions
      and run in parallel.

  The writer holds no per-collection state — it just applies the mutation
  against the shared ETS tables (`GiTF.Archive.apply_write/1`). The mutation is
  a handful of microsecond ETS operations with NO disk I/O and NO full-store
  read: durability is handled asynchronously by the Archive persister. That is
  what replaces the old single global `mkdir` lock that held across a full
  read + synchronous disk write.
  """

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @impl true
  def init(:ok), do: {:ok, :no_state}

  @impl true
  def handle_call({:apply, op}, _from, state) do
    {:reply, GiTF.Archive.apply_write(op), state}
  end
end
