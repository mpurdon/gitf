defmodule Hive.Run do
  @moduledoc """
  Context module for coordinated run management.

  A run represents a single execution attempt of a quest -- all the bees
  spawned to work on its jobs during one pass. Tracking runs lets the Queen
  know when every job in a batch has finished (completed or failed) so it
  can trigger quest completion or the next phase automatically.

  This is a pure context module: no process state, just data transformations
  against the Store.
  """

  alias Hive.Store

  # -- Public API --------------------------------------------------------------

  @doc """
  Creates a new run for a quest.

  Returns `{:ok, run}`.
  """
  @spec create(String.t(), keyword()) :: {:ok, map()}
  def create(quest_id, opts \\ []) do
    job_ids = Keyword.get(opts, :job_ids, [])

    record = %{
      quest_id: quest_id,
      status: "active",
      started_at: DateTime.utc_now(),
      completed_at: nil,
      bee_ids: [],
      job_ids: job_ids,
      total_jobs: length(job_ids),
      completed_jobs: 0,
      failed_jobs: 0
    }

    Store.insert(:runs, record)
  end

  @doc """
  Appends a bee ID to the run's bee list.

  Returns `{:ok, run}` or `{:error, :not_found}`.
  """
  @spec add_bee(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def add_bee(run_id, bee_id) do
    case Store.get(:runs, run_id) do
      nil ->
        {:error, :not_found}

      run ->
        updated = %{run | bee_ids: Enum.uniq([bee_id | run.bee_ids])}
        Store.put(:runs, updated)
    end
  end

  @doc """
  Appends a job ID to the run and increments total_jobs.

  Returns `{:ok, run}` or `{:error, :not_found}`.
  """
  @spec add_job(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def add_job(run_id, job_id) do
    case Store.get(:runs, run_id) do
      nil ->
        {:error, :not_found}

      run ->
        updated = %{
          run
          | job_ids: Enum.uniq([job_id | run.job_ids]),
            total_jobs: run.total_jobs + 1
        }

        Store.put(:runs, updated)
    end
  end

  @doc """
  Records a job completion within the run.

  Increments completed_jobs. If all jobs are resolved (completed + failed == total),
  marks the run as completed and returns `{:ok, run, :run_complete}`.
  Otherwise returns `{:ok, run}`.
  """
  @spec job_completed(String.t(), String.t()) ::
          {:ok, map()} | {:ok, map(), :run_complete} | {:error, :not_found}
  def job_completed(run_id, _job_id) do
    # Atomic increment via update_matching to prevent race on concurrent completions
    count = Store.update_matching(
      :runs,
      fn r -> r.id == run_id end,
      fn r -> %{r | completed_jobs: r.completed_jobs + 1} end
    )

    if count == 0 do
      {:error, :not_found}
    else
      case Store.get(:runs, run_id) do
        nil -> {:error, :not_found}
        run -> maybe_finish_check(run)
      end
    end
  end

  @doc """
  Records a job failure within the run.

  Increments failed_jobs. Same completion check as `job_completed/2`.
  """
  @spec job_failed(String.t(), String.t()) ::
          {:ok, map()} | {:ok, map(), :run_complete} | {:error, :not_found}
  def job_failed(run_id, _job_id) do
    count = Store.update_matching(
      :runs,
      fn r -> r.id == run_id end,
      fn r -> %{r | failed_jobs: r.failed_jobs + 1} end
    )

    if count == 0 do
      {:error, :not_found}
    else
      case Store.get(:runs, run_id) do
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
    Store.fetch(:runs, run_id)
  end

  @doc """
  Returns the active run (if any) for a given quest.
  """
  @spec active_for_quest(String.t()) :: map() | nil
  def active_for_quest(quest_id) do
    Store.find_one(:runs, fn r ->
      r.quest_id == quest_id and r.status == "active"
    end)
  end

  @doc """
  Lists runs with optional filters.

  ## Options

    * `:quest_id` - filter by quest
    * `:status` - filter by status ("active", "completed", "failed")
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    runs = Store.all(:runs)

    runs
    |> maybe_filter(:quest_id, Keyword.get(opts, :quest_id))
    |> maybe_filter(:status, Keyword.get(opts, :status))
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
  end

  @doc """
  Checks whether all bees in a run have stopped working.

  Returns `true` if every bee in the run is in "stopped", "crashed", or
  has no active worker process. Returns `false` if any bee is still working.
  """
  @spec all_idle?(String.t()) :: boolean()
  def all_idle?(run_id) do
    case Store.get(:runs, run_id) do
      nil ->
        true

      run ->
        Enum.all?(run.bee_ids, fn bee_id ->
          case Store.get(:bees, bee_id) do
            nil -> true
            %{status: status} -> status in ["stopped", "crashed", "done"]
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
      Store.put(:runs, finished)
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
