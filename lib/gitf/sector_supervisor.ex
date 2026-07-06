defmodule GiTF.SectorSupervisor do
  @moduledoc """
  DynamicSupervisor for ghost processes.

  Each ghost runs as a `:transient` child (see `GiTF.Ghost.Worker`'s
  child_spec): a clean `:normal` exit is not restarted, but an abnormal crash
  IS restarted by this supervisor, at which point the worker auto-resumes from
  its last checkpoint (`provision_auto_resume`). The Major coordinates ops but
  does not hand-roll ghost restarts.

  The supervisor itself uses `:one_for_one` strategy and lives in the
  Application supervision tree. It starts empty and children are added
  dynamically when ghosts are spawned.
  """

  use DynamicSupervisor

  @name GiTF.SectorSupervisor

  @doc "Starts the SectorSupervisor."
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

  @doc """
  Terminates a ghost worker child via the supervisor.

  Unlike `Process.exit(pid, :kill)`, a supervisor-initiated termination does
  **not** count as a restart, so a `:transient` worker is not revived into a
  second subprocess for the same op. Gives the worker's `terminate/2` a
  chance to run (killing its OS subprocess) before shutdown.
  """
  @spec terminate_child(pid()) :: :ok | {:error, :not_found}
  def terminate_child(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(@name, pid)
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
    # max_restarts raised to handle code-reload scenarios where all ghosts
    # crash simultaneously and need :transient restart
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 20, max_seconds: 10)
  end
end
