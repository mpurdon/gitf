defmodule GiTF.Run do
  @moduledoc """
  Context module for coordinated run management.

  A run represents a single execution attempt of a mission -- all the ghosts
  spawned to work on its ops during one pass. Tracking runs lets the Major
  know when every op in a batch has finished (completed or failed) so it
  can trigger mission completion or the next phase automatically.

  This is a pure context module: no process state, just data transformations
  against the Archive.
  """

  alias GiTF.Archive
  require GiTF.Ghost.Status, as: GhostStatus

  # -- Public API --------------------------------------------------------------

  @doc """
  Creates a new run for a mission.

  Returns `{:ok, run}`.
  """
  @spec create(String.t(), keyword()) :: {:ok, map()}
  def create(mission_id, opts \\ []) do
    op_ids = Keyword.get(opts, :op_ids, [])

    record = %{
      mission_id: mission_id,
      status: "active",
      started_at: DateTime.utc_now(),
      completed_at: nil,
      ghost_ids: [],
      op_ids: op_ids,
      total_jobs: length(op_ids),
      completed_jobs: 0,
      failed_jobs: 0
    }

    Archive.insert(:runs, record)
  end

  @doc """
  Appends a ghost ID to the run's ghost list.

  Returns `{:ok, run}` or `{:error, :not_found}`.
  """
  @spec add_bee(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def add_bee(run_id, ghost_id) do
    case Archive.get(:runs, run_id) do
      nil ->
        {:error, :not_found}

      run ->
        updated = %{run | ghost_ids: Enum.uniq([ghost_id | run.ghost_ids])}
        Archive.put(:runs, updated)
    end
  end

  @doc """
  Appends a op ID to the run and increments total_jobs.

  Returns `{:ok, run}` or `{:error, :not_found}`.
  """
  @spec add_job(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def add_job(run_id, op_id) do
    case Archive.get(:runs, run_id) do
      nil ->
        {:error, :not_found}

      run ->
        updated = %{
          run
          | op_ids: Enum.uniq([op_id | run.op_ids]),
            total_jobs: run.total_jobs + 1
        }

        Archive.put(:runs, updated)
    end
  end

  @doc """
  Records a op completion within the run.

  Increments completed_jobs. If all ops are resolved (completed + failed == total),
  marks the run as completed and returns `{:ok, run, :run_complete}`.
  Otherwise returns `{:ok, run}`.
  """
  @spec job_completed(String.t(), String.t()) ::
          {:ok, map()} | {:ok, map(), :run_complete} | {:error, :not_found}
  def job_completed(run_id, _op_id) do
    # Atomic increment via update_matching to prevent race on concurrent completions
    count =
      Archive.update_matching(
        :runs,
        fn r -> r.id == run_id end,
        fn r -> %{r | completed_jobs: r.completed_jobs + 1} end
      )

    if count == 0 do
      {:error, :not_found}
    else
      case Archive.get(:runs, run_id) do
        nil -> {:error, :not_found}
        run -> maybe_finish_check(run)
      end
    end
  end

  @doc """
  Records a op failure within the run.

  Increments failed_jobs. Same completion check as `job_completed/2`.
  """
  @spec job_failed(String.t(), String.t()) ::
          {:ok, map()} | {:ok, map(), :run_complete} | {:error, :not_found}
  def job_failed(run_id, _op_id) do
    count =
      Archive.update_matching(
        :runs,
        fn r -> r.id == run_id end,
        fn r -> %{r | failed_jobs: r.failed_jobs + 1} end
      )

    if count == 0 do
      {:error, :not_found}
    else
      case Archive.get(:runs, run_id) do
        nil -> {:error, :not_found}
        run -> maybe_finish_check(run)
      end
    end
  end

  @doc """
  Fetches a run by ID.

  Returns `{:ok, run}` or `{:error, :not_found}`.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(run_id) do
    Archive.fetch(:runs, run_id)
  end

  @doc """
  Returns the active run (if any) for a given mission.
  """
  @spec active_for_quest(String.t()) :: map() | nil
  def active_for_quest(mission_id) do
    Archive.find_one(:runs, fn r ->
      r.mission_id == mission_id and r.status == "active"
    end)
  end

  @doc """
  Lists runs with optional filters.

  ## Options

    * `:mission_id` - filter by mission
    * `:status` - filter by status ("active", "completed", "failed")
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    runs = Archive.all(:runs)

    runs
    |> maybe_filter(:mission_id, Keyword.get(opts, :mission_id))
    |> maybe_filter(:status, Keyword.get(opts, :status))
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
  end

  @doc """
  Checks whether all ghosts in a run have stopped working.

  Returns `true` if every ghost in the run is in "stopped", "crashed", or
  has no active worker process. Returns `false` if any ghost is still working.
  """
  @spec all_idle?(String.t()) :: boolean()
  def all_idle?(run_id) do
    case Archive.get(:runs, run_id) do
      nil ->
        true

      run ->
        Enum.all?(run.ghost_ids, fn ghost_id ->
          case Archive.get(:ghosts, ghost_id) do
            nil -> true
            %{status: status} -> GhostStatus.terminal?(status)
          end
        end)
    end
  end

  # -- Private -----------------------------------------------------------------

  # Check-only version for use after atomic update_matching (run already saved)
  defp maybe_finish_check(run) do
    resolved = run.completed_jobs + run.failed_jobs

    if resolved >= run.total_jobs and run.total_jobs > 0 do
      finished = %{run | status: "completed", completed_at: DateTime.utc_now()}
      Archive.put(:runs, finished)
      {:ok, finished, :run_complete}
    else
      {:ok, run}
    end
  end

  defp maybe_filter(runs, _field, nil), do: runs

  defp maybe_filter(runs, field, value) do
    Enum.filter(runs, &(Map.get(&1, field) == value))
  end
end
