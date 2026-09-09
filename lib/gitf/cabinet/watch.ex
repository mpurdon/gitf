defmodule GiTF.Cabinet.Watch do
  @moduledoc """
  The fleet watcher — keeps `Fleet.observe/1` running while nobody has
  the Console open, so a box that idle-stops at 3am still gets its
  "stopped since" recorded. One EC2 describe per ministry per minute;
  the Console's own refresh reads the remembered box between ticks.
  Cabinet mode only.
  """

  use GenServer

  require Logger

  alias GiTF.Cabinet.{Fleet, Registry}

  @tick :timer.minutes(1)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    send(self(), :tick)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    Enum.each(Registry.list(), &observe/1)
    Process.send_after(self(), :tick, @tick)
    {:noreply, state}
  end

  defp observe(ministry) do
    Fleet.observe(ministry)
  rescue
    err -> Logger.warning("Cabinet watch: #{ministry.slug} — #{Exception.message(err)}")
  end
end
