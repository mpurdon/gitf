defmodule GiTF.CombSupervisor do
  @moduledoc """
  DynamicSupervisor for ghost processes.

  Each ghost runs as a temporary child under this supervisor. When a ghost
  crashes or finishes, it is not automatically restarted -- the Major
  decides whether to respawn.

  The supervisor itself uses `:one_for_one` strategy and lives in the
  Application supervision tree. It starts empty and children are added
  dynamically when ghosts are spawned.
  """

  use DynamicSupervisor

  @name GiTF.CombSupervisor

  @doc "Starts the CombSupervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Starts a child process under this supervisor.

  The child spec should define a `:temporary` restart strategy so that
  finished or crashed ghosts are not automatically restarted.
  """
  @spec start_child(Supervisor.child_spec() | {module(), term()}) ::
          DynamicSupervisor.on_start_child()
  def start_child(child_spec) do
    DynamicSupervisor.start_child(@name, child_spec)
  end

  @doc "Returns the count of active children."
  @spec active_count() :: non_neg_integer()
  def active_count do
    %{active: count} = DynamicSupervisor.count_children(@name)
    count
  end

  @doc "Lists all running child PIDs."
  @spec children() :: [pid()]
  def children do
    DynamicSupervisor.which_children(@name)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&is_pid/1)
  end

  @impl true
  def init(_opts) do
    # Future scaling: For >10k ghosts, consider PartitionSupervisor
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
