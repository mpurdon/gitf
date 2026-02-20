defmodule Hive.Quests do
  @moduledoc """
  Context module for quest lifecycle management.

  A quest is a high-level objective decomposed into jobs. Its status is
  derived from the collective state of its jobs via `compute_status/1`,
  a pure function that maps job statuses to a quest status.

  This is a pure context module: no process state, just data transformations
  against the store.
  """

  alias Hive.Store

  # -- Public API --------------------------------------------------------------

  @doc """
  Creates a new quest.

  Required attrs: `goal`.
  Optional: `comb_id`, `name` (auto-generated from goal if omitted).

  Returns `{:ok, quest}` or `{:error, reason}`.
  """
  @spec create(map()) :: {:ok, map()} | {:error, term()}
  def create(attrs) do
    goal = attrs[:goal] || attrs["goal"]

    if is_nil(goal) or goal == "" do
      {:error, {:missing_fields, [:goal]}}
    else
      name = attrs[:name] || attrs["name"] || generate_name(goal)

      record = %{
        name: name,
        goal: goal,
        status: attrs[:status] || "pending",
        comb_id: attrs[:comb_id] || attrs["comb_id"],
        current_phase: "pending",
        research_summary: nil,
        implementation_plan: nil
      }

      Store.insert(:quests, record)
    end
  end

  defp generate_name(goal) do
    goal
    |> String.slice(0, 50)
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.trim()
    |> String.replace(~r/\s+/, "-")
  end

  @doc """
  Lists quests with optional status filter.

  ## Options

    * `:status` - filter by quest status
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    quests = Store.all(:quests)

    quests =
      case Keyword.get(opts, :status) do
        nil -> quests
        status -> Enum.filter(quests, &(&1.status == status))
      end

    Enum.sort_by(quests, & &1.inserted_at, {:desc, DateTime})
  end

  @doc """
  Deletes a quest by ID.

  Returns `:ok` or `{:error, :not_found}`.
  """
  @spec delete(String.t()) :: :ok | {:error, :not_found}
  def delete(quest_id) do
    case Store.get(:quests, quest_id) do
      nil -> {:error, :not_found}
      _quest -> Store.delete(:quests, quest_id)
    end
  end

  @doc """
  Closes a quest: removes all associated bee cells/worktrees, then marks status as "closed".

  Returns `{:ok, quest}` or `{:error, :not_found}`.
  """
  @spec close(String.t()) :: {:ok, map()} | {:error, :not_found}
  def close(quest_id) do
    with {:ok, quest} <- get(quest_id) do
      bee_ids = quest.jobs |> Enum.map(& &1.bee_id) |> Enum.reject(&is_nil/1)

      Enum.each(bee_ids, fn bee_id ->
        case Store.find_one(:cells, fn c -> c.bee_id == bee_id and c.status == "active" end) do
          nil -> :ok
          cell -> Hive.Cell.remove(cell.id, force: true)
        end
      end)

      updated = %{quest | status: "closed"} |> Map.delete(:jobs)
      Store.put(:quests, updated)
    end
  end

  @doc """
  Gets a quest by ID, with its jobs attached.

  Returns `{:ok, quest}` or `{:error, :not_found}`.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(quest_id) do
    case Store.get(:quests, quest_id) do
      nil ->
        {:error, :not_found}

      quest ->
        jobs = Hive.Jobs.list(quest_id: quest_id)
        {:ok, Map.put(quest, :jobs, jobs)}
    end
  end

  @doc """
  Computes a quest's status from its jobs' statuses.

  This is a pure function -- it takes a list of job status strings and
  returns the derived quest status. No store access.

  ## Rules

    * No jobs or all pending -> "pending"
    * All done -> "completed"
    * Any failed -> "failed"
    * Any running or assigned -> "active"
    * Otherwise -> "pending"
  """
  @spec compute_status([String.t()]) :: String.t()
  def compute_status([]), do: "pending"

  def compute_status(job_statuses) do
    cond do
      Enum.all?(job_statuses, &(&1 == "done")) ->
        "completed"

      Enum.any?(job_statuses, &(&1 == "failed")) ->
        "failed"

      Enum.any?(job_statuses, &(&1 in ["running", "assigned"])) ->
        "active"

      true ->
        "pending"
    end
  end

  @doc """
  Transitions a quest from "pending" to "planning" status.

  Returns `{:ok, quest}` or `{:error, :not_found | :invalid_transition}`.
  """
  @spec set_planning(String.t()) :: {:ok, map()} | {:error, term()}
  def set_planning(quest_id) do
    case Store.get(:quests, quest_id) do
      nil ->
        {:error, :not_found}

      %{status: "pending"} = quest ->
        updated = %{quest | status: "planning"}
        Store.put(:quests, updated)

      _quest ->
        {:error, :invalid_transition}
    end
  end

  @doc """
  Recomputes and persists a quest's status from its current jobs.

  If the quest is in "planning" status and has no jobs yet, the status is
  preserved (not downgraded to "pending"). Once jobs exist, normal
  computation resumes.

  Returns `{:ok, quest}` or `{:error, reason}`.
  """
  @spec update_status!(String.t()) :: {:ok, map()} | {:error, term()}
  def update_status!(quest_id) do
    with {:ok, quest} <- get(quest_id) do
      job_statuses = Enum.map(quest.jobs, & &1.status)

      if quest.status == "planning" and job_statuses == [] do
        {:ok, quest |> Map.delete(:jobs)}
      else
        new_status = compute_status(job_statuses)
        updated = %{quest | status: new_status} |> Map.delete(:jobs)
        Store.put(:quests, updated)
      end
    end
  end

  @doc """
  Adds a job to a quest.

  Merges the quest_id into the job attrs and delegates to `Hive.Jobs.create/1`.

  Returns `{:ok, job}` or `{:error, reason}`.
  """
  @spec add_job(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def add_job(quest_id, job_attrs) do
    job_attrs
    |> Map.put(:quest_id, quest_id)
    |> Hive.Jobs.create()
  end

  # -- Phase Management --------------------------------------------------------

  @doc """
  Transitions a quest to a new phase.

  Records the transition and updates the quest's current_phase.
  Returns `{:ok, quest}` or `{:error, reason}`.
  """
  @spec transition_phase(String.t(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def transition_phase(quest_id, to_phase, reason \\ nil) do
    case Store.get(:quests, quest_id) do
      nil ->
        {:error, :not_found}

      quest ->
        from_phase = Map.get(quest, :current_phase, "pending")
        
        # Record transition with monotonic sequence for ordering
        transition = %{
          quest_id: quest_id,
          from_phase: from_phase,
          to_phase: to_phase,
          reason: reason,
          seq: System.monotonic_time(:microsecond)
        }
        Store.insert(:quest_phase_transitions, transition)

        # Update quest
        updated = Map.put(quest, :current_phase, to_phase)
        Store.put(:quests, updated)
    end
  end

  @doc """
  Gets phase transition history for a quest.
  """
  @spec get_phase_transitions(String.t()) :: [map()]
  def get_phase_transitions(quest_id) do
    Store.filter(:quest_phase_transitions, fn t -> t.quest_id == quest_id end)
    |> Enum.sort_by(&Map.get(&1, :seq, 0))
  end
end
