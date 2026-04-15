defmodule GiTF.TUI.Context.Activity do
  @moduledoc """
  Manages the activity status, including factory health, active ghosts, and missions.
  """

  defstruct factory_status: :ok, ghosts: [], missions: [], ghost_logs: %{}

  @type t :: %__MODULE__{
          factory_status: :ok | :error | :maintenance,
          ghosts: list(map()),
          missions: list(map()),
          ghost_logs: map()
        }

  def new do
    %__MODULE__{}
  end

  def update_factory_status(state, status) do
    %{state | factory_status: status}
  end

  def update_bees(state, ghosts) do
    %{state | ghosts: ghosts}
  end

  def update_quests(state, missions) do
    %{state | missions: missions}
  end

  def update_ghost_logs(state, ghost_logs) do
    %{state | ghost_logs: ghost_logs}
  end
end
