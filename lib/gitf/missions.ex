defmodule GiTF.Missions do
  @moduledoc """
  Context module for mission lifecycle management.

  A mission is a high-level objective decomposed into ops. Its status is
  derived from the collective state of its ops via `compute_status/1`,
  a pure function that maps op statuses to a mission status.

  This is a pure context module: no process state, just data transformations
  against the store.
  """

  alias GiTF.Archive

  # -- Public API --------------------------------------------------------------

  @doc """
  Creates a new mission.

  Required attrs: `goal`.
  Optional: `sector_id`, `name` (auto-generated from goal if omitted).

  Returns `{:ok, mission}` or `{:error, reason}`.
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
        sector_id: attrs[:sector_id] || attrs["sector_id"],
        current_phase: "pending",
        review_plan: attrs[:review_plan] || attrs["review_plan"] || false,
        research_summary: nil,
        implementation_plan: nil,
        artifacts: %{},
        phase_jobs: %{}
      }

      case Archive.insert(:missions, record) do
        {:ok, mission} = result ->
          GiTF.Telemetry.emit([:gitf, :mission, :created], %{}, %{
            mission_id: mission.id,
            name: name
          })

          result

        error ->
          error
      end
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
  Lists missions with optional status filter.

  ## Options

    * `:status` - filter by mission status
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    missions =
      Archive.all(:missions)
      |> Enum.map(&derive_status/1)

    missions =
      case Keyword.get(opts, :status) do
        nil -> missions
        status -> Enum.filter(missions, &(&1.status == status))
      end

    Enum.sort_by(missions, & &1.inserted_at, {:desc, DateTime})
  end

  # Derives status from current_phase when the stored status is stale.
  defp derive_status(%{current_phase: phase, status: "pending"} = mission)
       when phase not in [nil, "pending"] do
    %{mission | status: "active"}
  end

  defp derive_status(mission), do: mission

  @doc "Update fields on a mission record."
  @spec update(String.t(), map()) :: {:ok, map()} | {:error, :not_found}
  def update(mission_id, attrs) do
    case Archive.get(:missions, mission_id) do
      nil -> {:error, :not_found}
      mission ->
        updated = Map.merge(mission, attrs)
        Archive.put(:missions, updated)
        {:ok, updated}
    end
  end

  @doc """
  Deletes a mission by ID.

  Returns `:ok` or `{:error, :not_found}`.
  """
  @spec delete(String.t()) :: :ok | {:error, :not_found}
  def delete(mission_id) do
    # Kill first to clean up ops, ghosts, shells/worktrees, then delete
    kill(mission_id)
  end

  @doc """
  Kills a mission: kills all its ops (stopping ghosts, removing shells),
  removes all op dependencies, deletes all ops, then deletes the mission.

  Returns `:ok` or `{:error, :not_found}`.
  """
  @spec kill(String.t()) :: :ok | {:error, :not_found}
  def kill(mission_id) do
    case Archive.get(:missions, mission_id) do
      nil ->
        {:error, :not_found}

      _quest ->
        GiTF.Ops.list(mission_id: mission_id)
        |> Enum.each(fn op -> GiTF.Ops.kill(op[:id] || op.id) end)

        Archive.delete(:missions, mission_id)
        :ok
    end
  end

  @doc """
  Closes a mission: removes all associated ghost shells/worktrees, then marks status as "closed".

  Returns `{:ok, mission}` or `{:error, :not_found}`.
  """
  @spec close(String.t()) :: {:ok, map()} | {:error, :not_found}
  def close(mission_id) do
    with {:ok, mission} <- get(mission_id) do
      ghost_ids = mission.ops |> Enum.map(& &1.ghost_id) |> Enum.reject(&is_nil/1)

      Enum.each(ghost_ids, fn ghost_id ->
        case Archive.find_one(:shells, fn c -> c.ghost_id == ghost_id and c.status == "active" end) do
          nil -> :ok
          shell -> GiTF.Shell.remove(shell.id, force: true)
        end
      end)

      updated = %{mission | status: "closed"} |> Map.delete(:ops)
      Archive.put(:missions, updated)
    end
  end

  @doc """
  Gets a mission by ID, with its ops attached.

  Returns `{:ok, mission}` or `{:error, :not_found}`.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(mission_id) do
    case Archive.get(:missions, mission_id) do
      nil ->
        {:error, :not_found}

      mission ->
        ops = GiTF.Ops.list(mission_id: mission_id)
        {:ok, Map.put(mission, :ops, ops)}
    end
  end

  @doc """
  Computes a mission's status from its ops' statuses.

  This is a pure function -- it takes a list of op status strings and
  returns the derived mission status. No store access.

  ## Rules

    * No ops or all pending -> "pending"
    * All done -> "completed"
    * Any failed -> "failed"
    * Any running or assigned -> "active"
    * Otherwise -> "pending"
  """
  @spec compute_status([String.t()]) :: String.t()
  def compute_status([]), do: "pending"

  def compute_status(op_statuses) do
    has_running = Enum.any?(op_statuses, &(&1 in ["running", "assigned"]))
    has_failed = Enum.any?(op_statuses, &(&1 == "failed"))
    has_pending = Enum.any?(op_statuses, &(&1 in ["pending", "blocked"]))

    cond do
      Enum.all?(op_statuses, &(&1 == "done")) ->
        "completed"

      has_running ->
        "active"

      has_failed and not has_running and not has_pending ->
        "failed"

      has_pending or has_failed ->
        "active"

      true ->
        "pending"
    end
  end

  @doc """
  Transitions a mission from "pending" to "planning" status.

  Returns `{:ok, mission}` or `{:error, :not_found | :invalid_transition}`.
  """
  @spec set_planning(String.t()) :: {:ok, map()} | {:error, term()}
  def set_planning(mission_id) do
    case Archive.get(:missions, mission_id) do
      nil ->
        {:error, :not_found}

      %{status: "pending"} = mission ->
        updated = %{mission | status: "planning"}
        Archive.put(:missions, updated)

      _quest ->
        {:error, :invalid_transition}
    end
  end

  @doc """
  Recomputes and persists a mission's status from its current ops.

  If the mission is in "planning" status and has no ops yet, the status is
  preserved (not downgraded to "pending"). Once ops exist, normal
  computation resumes.

  Returns `{:ok, mission}` or `{:error, reason}`.
  """
  # Phases where implementation ops are done but the mission isn't finished yet.
  # Only `complete_quest` (via `transition_phase`) should mark "completed".
  @post_impl_phases ["validation", "awaiting_approval", "sync", "simplify", "scoring"]

  @spec update_status!(String.t()) :: {:ok, map()} | {:error, term()}
  def update_status!(mission_id) do
    with {:ok, mission} <- get(mission_id) do
      impl_jobs = Enum.reject(mission.ops, & &1[:phase_job])

      # Exclude failed ops that have been retried (active retry exists)
      retried_ids = impl_jobs
        |> Enum.map(& &1[:retry_of])
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      active_jobs = Enum.reject(impl_jobs, fn op ->
        op.status == "failed" and MapSet.member?(retried_ids, op.id)
      end)

      op_statuses = Enum.map(active_jobs, & &1.status)

      if mission.status == "planning" and op_statuses == [] do
        {:ok, mission |> Map.delete(:ops)}
      else
        new_status = compute_status(op_statuses)

        # Don't allow "completed" while still in post-implementation phases —
        # simplify/scoring/sync must finish first via complete_quest
        new_status =
          if new_status == "completed" and Map.get(mission, :current_phase) in @post_impl_phases do
            "active"
          else
            new_status
          end

        updated = %{mission | status: new_status} |> Map.delete(:ops)
        result = Archive.put(:missions, updated)

        if new_status == "completed" and mission.status != "completed" do
          GiTF.Telemetry.emit([:gitf, :mission, :completed], %{}, %{
            mission_id: mission.id,
            name: mission.name
          })
        end

        result
      end
    end
  end

  @doc """
  Adds a op to a mission.

  Syncs the mission_id into the op attrs and delegates to `GiTF.Ops.create/1`.

  Returns `{:ok, op}` or `{:error, reason}`.
  """
  @spec add_job(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def add_job(mission_id, job_attrs) do
    job_attrs
    |> Map.put(:mission_id, mission_id)
    |> GiTF.Ops.create()
  end

  # -- Artifact Storage --------------------------------------------------------

  @doc """
  Stores a phase artifact on a mission record.

  Syncs the artifact into the mission's `artifacts` map under the given phase key.
  Returns `{:ok, mission}` or `{:error, :not_found}`.
  """
  @spec store_artifact(String.t(), String.t(), map()) :: {:ok, map()} | {:error, :not_found}
  def store_artifact(mission_id, phase, artifact) do
    case Archive.get(:missions, mission_id) do
      nil ->
        {:error, :not_found}

      mission ->
        artifacts = Map.get(mission, :artifacts, %{})
        updated = Map.put(mission, :artifacts, Map.put(artifacts, phase, artifact))
        Archive.put(:missions, updated)
    end
  end

  @doc """
  Gets a phase artifact from a mission record.

  Returns the artifact map or nil if not found.
  """
  @spec get_artifact(String.t(), String.t()) :: map() | nil
  def get_artifact(mission_id, phase) do
    case Archive.get(:missions, mission_id) do
      nil -> nil
      mission -> get_in(mission, [:artifacts, phase]) || get_in(mission, [:artifacts, Access.key(phase)])
    end
  end

  @doc """
  Records which op serves which phase on a mission.

  Returns `{:ok, mission}` or `{:error, :not_found}`.
  """
  @spec record_phase_job(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def record_phase_job(mission_id, phase, op_id) do
    case Archive.get(:missions, mission_id) do
      nil ->
        {:error, :not_found}

      mission ->
        phase_jobs = Map.get(mission, :phase_jobs, %{})
        updated = Map.put(mission, :phase_jobs, Map.put(phase_jobs, phase, op_id))
        Archive.put(:missions, updated)
    end
  end

  # -- Phase Management --------------------------------------------------------

  @doc """
  Transitions a mission to a new phase.

  Records the transition and updates the mission's current_phase.
  Returns `{:ok, mission}` or `{:error, reason}`.
  """
  @spec transition_phase(String.t(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def transition_phase(mission_id, to_phase, reason \\ nil) do
    case Archive.get(:missions, mission_id) do
      nil ->
        {:error, :not_found}

      mission ->
        from_phase = Map.get(mission, :current_phase, "pending")

        # Record transition with monotonic sequence for ordering
        transition = %{
          mission_id: mission_id,
          from_phase: from_phase,
          to_phase: to_phase,
          reason: reason,
          seq: System.monotonic_time(:microsecond)
        }
        Archive.insert(:mission_phase_transitions, transition)

        # Update mission phase and derive status from the phase
        status =
          case to_phase do
            "completed" -> mission.status
            "pending" -> "pending"
            _ -> "active"
          end

        updated =
          mission
          |> Map.put(:current_phase, to_phase)
          |> Map.put(:status, status)

        Archive.put(:missions, updated)
    end
  end

  @doc """
  Gets phase transition history for a mission.
  """
  @spec get_phase_transitions(String.t()) :: [map()]
  def get_phase_transitions(mission_id) do
    Archive.filter(:mission_phase_transitions, fn t -> t.mission_id == mission_id end)
    |> Enum.sort_by(&Map.get(&1, :seq, 0))
  end
end
