defmodule GiTF.Plugin.Builtin.Commands.Quit do
  @moduledoc "Built-in /quit command. Initiates graceful exfil."

  use GiTF.Plugin, type: :command

  @impl true
  def name, do: "quit"

  @impl true
  def description, do: "Quit GiTF"

  @impl true
  def execute(_args, _ctx) do
    GiTF.Exfil.initiate()
    :ok
  end

  @impl true
  def completions(_partial), do: []
end
