defmodule GiTF.Missions do
  @moduledoc """
  Context module for mission lifecycle management.

  A mission is a high-level objective decomposed into ops. Its status is
  derived from the collective state of its ops via `compute_status/1`,
  a pure function that maps op statuses to a mission status.

  This is a pure context module: no process state, just data transformations
  against the store.
  """

  require Logger

  alias GiTF.Archive

  # Mission statuses considered "in flight" — mission is still actively being
  # worked on. Used by budget/scaling/watchdog to identify live missions.
  @active_statuses ~w(
    active implementation research design review
    planning validation requirements
  )

  @doc "Returns the list of mission statuses considered active (in flight)."
  @spec active_statuses() :: [String.t()]
  def active_statuses, do: @active_statuses

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

      # Priority: use explicit value, infer from goal, or default
      {priority, priority_source} =
        case attrs[:priority] || attrs["priority"] do
          p when is_atom(p) and p != nil ->
            if GiTF.Priority.valid?(p),
              do: {p, :manual},
              else: GiTF.Priority.infer_from_goal(goal)

          p when is_binary(p) ->
            case GiTF.Priority.parse(p) do
              {:ok, parsed} -> {parsed, :manual}
              _ -> GiTF.Priority.infer_from_goal(goal)
            end

          _ ->
            GiTF.Priority.infer_from_goal(goal)
        end

      record = %{
        name: name,
        goal: goal,
        status: attrs[:status] || "pending",
        sector_id: attrs[:sector_id] || attrs["sector_id"],
        current_phase: "pending",
        phase_advance_seq: 0,
        priority: priority,
        priority_source: priority_source,
        priority_set_at: DateTime.utc_now(),
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
            name: name,
            priority: priority,
            priority_source: priority_source
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
      nil ->
        {:error, :not_found}

      mission ->
        updated = Map.merge(mission, attrs)
        Archive.put(:missions, updated)
        {:ok, updated}
    end
  end

  @doc """
  Updates a mission's priority and resets the decay clock.

  Returns `{:ok, updated_mission}` or `{:error, reason}`.
  """
  @spec update_priority(String.t(), atom()) :: {:ok, map()} | {:error, term()}
  def update_priority(mission_id, priority) do
    if not GiTF.Priority.valid?(priority) do
      {:error, :invalid_priority}
    else
      old_priority =
        case Archive.get(:missions, mission_id) do
          %{priority: p} -> p
          _ -> :normal
        end

      case update(mission_id, %{
             priority: priority,
             priority_source: :manual,
             priority_set_at: DateTime.utc_now()
           }) do
        {:ok, updated} ->
          GiTF.Telemetry.emit([:gitf, :mission, :priority_changed], %{}, %{
            mission_id: mission_id,
            old_priority: old_priority,
            new_priority: priority
          })

          {:ok, updated}

        error ->
          error
      end
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
  In Dark Factory mode, also rolls back the sector worktree to a clean state.

  Returns `:ok` or `{:error, :not_found}`.
  """
  @spec kill(String.t()) :: :ok | {:error, :not_found}
  def kill(mission_id) do
    case Archive.get(:missions, mission_id) do
      nil ->
        {:error, :not_found}

      quest ->
        # Rollback sector if applicable
        rollback_sector(quest)

        GiTF.Ops.list(mission_id: mission_id)
        |> Enum.each(fn op -> GiTF.Ops.kill(op[:id] || op.id) end)

        Archive.delete(:missions, mission_id)
        :ok
    end
  end

  defp rollback_sector(%{sector_id: sid}) when is_binary(sid) do
    case Archive.get(:sectors, sid) do
      %{path: path} when is_binary(path) ->
        if File.dir?(path) do
          GiTF.Git.rollback(path)
        end

      _ ->
        :ok
    end
  end

  defp rollback_sector(_), do: :ok

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
  # Include "implementation" — ops finishing doesn't mean the mission is done;
  # validation, sync, simplify, and scoring still need to run.
  @pipeline_phases ["implementation", "validation", "awaiting_approval", "sync", "simplify", "scoring"]

  @spec update_status!(String.t()) :: {:ok, map()} | {:error, term()}
  def update_status!(mission_id) do
    # Read ops fresh — these are in a separate collection, not affected by the mission lock
    ops = GiTF.Ops.list(mission_id: mission_id)
    impl_jobs = Enum.reject(ops, & &1[:phase_job])

    retried_ids =
      impl_jobs
      |> Enum.map(& &1[:retry_of])
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    active_jobs =
      Enum.reject(impl_jobs, fn op ->
        op.status == "failed" and MapSet.member?(retried_ids, op.id)
      end)

    op_statuses = Enum.map(active_jobs, & &1.status)

    # Atomic read-modify-write on the mission record
    result =
      Archive.update(:missions, mission_id, fn mission ->
        if mission.status == "planning" and op_statuses == [] do
          mission
        else
          new_status = compute_status(op_statuses)

          new_status =
            if new_status == "completed" and Map.get(mission, :current_phase) in @pipeline_phases do
              Logger.debug("Mission #{mission_id}: suppressing premature 'completed' — still in #{mission.current_phase} phase")
              "active"
            else
              new_status
            end

          %{mission | status: new_status}
        end
      end)

    # Emit telemetry outside the lock
    case result do
      {:ok, %{status: "completed"} = mission} ->
        GiTF.Telemetry.emit([:gitf, :mission, :completed], %{}, %{
          mission_id: mission.id,
          name: mission[:name]
        })

      _ ->
        :ok
    end

    result
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
    Archive.update(:missions, mission_id, fn mission ->
      artifacts = Map.get(mission, :artifacts, %{})
      Map.put(mission, :artifacts, Map.put(artifacts, phase, artifact))
    end)
  end

  @doc """
  Compacts artifacts for all completed missions older than `days`.

  Replaces bulky phase artifacts with compact stubs, keeping only
  requirements and scoring (small and useful for queries).
  Returns count of missions compacted.
  """
  @spec compact_old_artifacts(pos_integer()) :: non_neg_integer()
  def compact_old_artifacts(days) do
    cutoff = DateTime.shift(DateTime.utc_now(), day: -days)

    Archive.filter(:missions, fn m ->
      m.status in ["completed", "failed"] and
        m[:updated_at] != nil and
        DateTime.compare(m.updated_at, cutoff) == :lt and
        has_uncompacted_artifacts?(m)
    end)
    |> Enum.count(fn mission ->
      compact_artifacts(mission.id)
      true
    end)
  rescue
    _ -> 0
  end

  @keep_artifacts ~w(requirements scoring)

  @doc """
  Replaces bulky artifacts with compact stubs for a single mission.
  Keeps requirements and scoring intact.
  """
  @spec compact_artifacts(String.t()) :: :ok
  def compact_artifacts(mission_id) do
    case Archive.get(:missions, mission_id) do
      nil ->
        :ok

      mission ->
        artifacts = Map.get(mission, :artifacts, %{})

        compacted =
          Map.new(artifacts, fn {phase, artifact} ->
            if phase in @keep_artifacts or is_compacted?(artifact) do
              {phase, artifact}
            else
              {phase,
               %{
                 "compacted" => true,
                 "phase" => phase,
                 "compacted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
               }}
            end
          end)

        Archive.put(:missions, Map.put(mission, :artifacts, compacted))
        :ok
    end
  end

  defp has_uncompacted_artifacts?(mission) do
    artifacts = Map.get(mission, :artifacts, %{})

    Enum.any?(artifacts, fn {phase, artifact} ->
      phase not in @keep_artifacts and not is_compacted?(artifact)
    end)
  end

  defp is_compacted?(%{"compacted" => true}), do: true
  defp is_compacted?(_), do: false

  @doc """
  Gets a phase artifact from a mission record.

  Returns the artifact map or nil if not found.
  """
  @spec get_artifact(String.t(), String.t()) :: map() | nil
  def get_artifact(mission_id, phase) do
    case Archive.get(:missions, mission_id) do
      nil ->
        nil

      mission ->
        get_in(mission, [:artifacts, phase]) || get_in(mission, [:artifacts, Access.key(phase)])
    end
  end

  @doc """
  Records which op serves which phase on a mission.

  Returns `{:ok, mission}` or `{:error, :not_found}`.
  """
  @spec record_phase_job(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found}
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
  @spec transition_phase(String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def transition_phase(mission_id, to_phase, reason \\ nil) do
    case Archive.get(:missions, mission_id) do
      nil ->
        {:error, :not_found}

      mission ->
        from_phase = Map.get(mission, :current_phase, "pending")

        if !recent_duplicate_transition?(mission_id, from_phase, to_phase) do
          Archive.insert(:mission_phase_transitions, %{
            mission_id: mission_id,
            from_phase: from_phase,
            to_phase: to_phase,
            reason: reason,
            seq: System.monotonic_time(:microsecond)
          })

          # Record in event store for timeline visibility
          GiTF.EventStore.record(:phase_transition, mission_id, %{
            from: from_phase,
            to: to_phase,
            reason: reason
          })
        end

        # Update mission phase and derive status from the phase.
        # The put is always idempotent — same value is harmless.
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

  # Returns true if an identical transition was recorded in the last 30 seconds.
  # Prevents the append-only log from accumulating duplicates when the same
  # phase advance is triggered multiple times (link_received retry, recovery cycles).
  defp recent_duplicate_transition?(mission_id, from_phase, to_phase) do
    cutoff = DateTime.shift(DateTime.utc_now(), second: -30)

    Archive.filter(:mission_phase_transitions, fn t ->
      t.mission_id == mission_id and
        t.from_phase == from_phase and
        t.to_phase == to_phase and
        compare_at(t, cutoff) == :gt
    end)
    |> Enum.any?()
  rescue
    _ -> false
  end

  defp compare_at(%{inserted_at: %DateTime{} = dt}, cutoff), do: DateTime.compare(dt, cutoff)
  defp compare_at(_, _), do: :lt

  @doc """
  Gets phase transition history for a mission.
  """
  @spec get_phase_transitions(String.t()) :: [map()]
  def get_phase_transitions(mission_id) do
    Archive.filter(:mission_phase_transitions, fn t -> t.mission_id == mission_id end)
    |> Enum.sort_by(&Map.get(&1, :seq, 0))
  end
end
