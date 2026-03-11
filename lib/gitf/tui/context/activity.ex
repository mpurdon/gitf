defmodule GiTF.TUI.Context.Activity do
  @moduledoc """
  Manages the activity status, including factory health, active ghosts, and quests.
  """

  defstruct factory_status: :ok, ghosts: [], quests: [], bee_logs: %{}

  @type t :: %__MODULE__{
          factory_status: :ok | :error | :maintenance,
          ghosts: list(map()),
          quests: list(map()),
          bee_logs: map()
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

  def update_quests(state, quests) do
    %{state | quests: quests}
  end

  def update_bee_logs(state, bee_logs) do
    %{state | bee_logs: bee_logs}
  end
end
