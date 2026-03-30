defmodule GiTF.Ops do
  @moduledoc """
  Context module for op lifecycle management.

  A op is a unit of work assigned to a ghost within a mission. This module
  enforces valid status transitions -- the state machine that governs how
  a op moves from pending through to done or failed.

  Status transitions:

      pending --> assigned --> running --> done
                                     \\--> failed
      pending --> blocked --> pending (unblock)
      running --> blocked

  This is a pure context module: no process state, just data transformations
  against the store.
  """

  alias GiTF.Archive
  require GiTF.Ghost.Status, as: GhostStatus

  # -- Valid transitions -------------------------------------------------------

  @transitions %{
    {"pending", :assign} => "assigned",
    {"assigned", :start} => "running",
    {"running", :complete} => "done",
    {"running", :fail} => "failed",
    {"done", :reject} => "rejected",
    {"failed", :reset} => "pending",
    {"rejected", :reset} => "pending",
    {"failed", :revive} => "running",
    {"pending", :block} => "blocked",
    {"running", :block} => "blocked",
    {"blocked", :unblock} => "pending"
  }

  # -- Public API --------------------------------------------------------------

  @doc """
  Creates a new op.

  Required attrs: `title`, `mission_id`, `sector_id`.
  Optional: `description`, `status`, `ghost_id`.

  Returns `{:ok, op}` or `{:error, reason}`.
  """
  @spec create(map()) :: {:ok, map()} | {:error, term()}
  def create(attrs) do
    with :ok <- validate_required(attrs, [:title, :mission_id, :sector_id]) do
      # Auto-classify and recommend model if not provided
      classification =
        if attrs[:op_type] && attrs[:recommended_model] do
          %{
            op_type: attrs[:op_type],
            complexity: attrs[:complexity] || "moderate",
            recommended_model: attrs[:recommended_model],
            reason: attrs[:model_selection_reason]
          }
        else
          GiTF.Ops.Classifier.classify_and_recommend(
            attrs[:title] || attrs["title"],
            attrs[:description] || attrs["description"]
          )
        end

      record = %{
        title: attrs[:title] || attrs["title"],
        description: attrs[:description] || attrs["description"],
        status: attrs[:status] || attrs["status"] || "pending",
        mission_id: attrs[:mission_id] || attrs["mission_id"],
        sector_id: attrs[:sector_id] || attrs["sector_id"],
        ghost_id: attrs[:ghost_id] || attrs["ghost_id"],
        # Multi-model support fields
        op_type: classification.op_type,
        complexity: classification.complexity,
        recommended_model: classification.recommended_model,
        assigned_model: attrs[:assigned_model] || classification.recommended_model,
        model_selection_reason: classification[:reason],
        verification_criteria: attrs[:verification_criteria] || [],
        estimated_context_tokens: attrs[:estimated_context_tokens],
        # Phase op fields
        phase_job: attrs[:phase_job] || false,
        phase: attrs[:phase],
        acceptance_criteria: attrs[:acceptance_criteria] || [],
        target_files: attrs[:target_files] || [],
        # Audit fields
        verification_status: "pending",
        audit_result: nil,
        verified_at: nil,
        # Risk level for adaptive permissions
        risk_level: classification[:risk_level] || attrs[:risk_level] || :low,
        # Retry tracking (persisted, survives Major restarts)
        retry_count: attrs[:retry_count] || 0,
        # Per-op verification contract
        verification_contract: attrs[:verification_contract],
        # Recon fields
        recon: attrs[:recon] || false,
        scout_for: attrs[:scout_for],
        scout_findings: attrs[:scout_findings],
        # Triage result
        triage_result: attrs[:triage_result],
        # Skip verification (simple ops, recon ops)
        skip_verification: attrs[:skip_verification] || false
      }

      Archive.insert(:ops, record)
    end
  end

  @doc """
  Assigns a op to a ghost.

  Transitions: pending -> assigned.
  """
  @spec assign(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def assign(op_id, ghost_id) do
    with {:ok, op} <- get(op_id),
         {:ok, next_status} <- validate_transition(op.status, :assign) do
      updated = %{op | status: next_status, ghost_id: ghost_id}
      Archive.put(:ops, updated)
    end
  end

  @doc "Starts a op. Transitions: assigned -> running."
  @spec start(String.t()) :: {:ok, map()} | {:error, atom()}
  def start(op_id), do: transition(op_id, :start)

  @doc "Completes a op. Transitions: running -> done."
  @spec complete(String.t()) :: {:ok, map()} | {:error, atom()}
  def complete(op_id), do: transition(op_id, :complete)

  @doc "Fails a op. Transitions: running -> failed."
  @spec fail(String.t()) :: {:ok, map()} | {:error, atom()}
  def fail(op_id), do: transition(op_id, :fail)

  @doc "Blocks a op. Transitions: pending | running -> blocked."
  @spec block(String.t()) :: {:ok, map()} | {:error, atom()}
  def block(op_id), do: transition(op_id, :block)

  @doc "Unblocks a op. Transitions: blocked -> pending."
  @spec unblock(String.t()) :: {:ok, map()} | {:error, atom()}
  def unblock(op_id), do: transition(op_id, :unblock)

  @doc "Rejects a completed op that failed verification. Transitions: done -> rejected."
  @spec reject(String.t()) :: {:ok, map()} | {:error, atom()}
  def reject(op_id), do: transition(op_id, :reject)

  @doc """
  Creates a retry op copying attrs from the original, with `retry_of` linkage.

  Increments retry_count. Appends failure feedback to the description so the
  next ghost has context on what went wrong. Returns `{:ok, new_job}` or
  `{:error, reason}`.

  ## Options

    * `:max_retries` — maximum allowed retries (default: 3)
    * `:feedback` — failure context to append to description
  """
  @spec create_retry(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_retry(op_id, opts \\ []) do
    with {:ok, op} <- get(op_id) do
      retry_count = Map.get(op, :retry_count, 0) + 1
      max_retries = Keyword.get(opts, :max_retries, 3)

      if retry_count > max_retries do
        {:error, :max_retries_exceeded}
      else
        feedback = Keyword.get(opts, :feedback)

        description =
          if feedback do
            (op.description || "") <>
              "\n\n## Feedback from attempt #{retry_count}:\n" <> feedback
          else
            op.description
          end

        attrs = %{
          title: op.title,
          description: description,
          mission_id: op.mission_id,
          sector_id: op.sector_id,
          retry_count: retry_count,
          retry_of: op.id,
          acceptance_criteria: Map.get(op, :acceptance_criteria, []),
          target_files: Map.get(op, :target_files, []),
          verification_criteria: Map.get(op, :verification_criteria, []),
          verification_contract: op[:verification_contract]
        }

        create(attrs)
      end
    end
  end

  @doc """
  Resets a failed op back to pending so it can be retried.

  Transitions: failed -> pending. Also stops the assigned ghost,
  cleans up its shell/worktree, and clears the ghost_id assignment
  so the op can be assigned to a fresh ghost.
  
  Optionally appends feedback to the op description.
  """
  @spec reset(String.t(), String.t() | nil) :: {:ok, map()} | {:error, atom()}
  def reset(op_id, feedback \\ nil) do
    with {:ok, op} <- get(op_id),
         {:ok, next_status} <- validate_transition(op.status, :reset) do
      cleanup_bee_and_cell(op.ghost_id)
      
      new_description = 
        if feedback do
          (op.description || "") <> "\n\n## Feedback from previous attempt:\n\n" <> feedback
        else
          op.description
        end

      retry_count = Map.get(op, :retry_count, 0) + 1
      updated = %{op | status: next_status, ghost_id: nil, retry_count: retry_count, description: new_description}
      result = Archive.put(:ops, updated)

      # Nudge Major's spawner so the reset op gets picked up immediately
      case Process.whereis(GiTF.Major) do
        pid when is_pid(pid) -> send(pid, :spawn_ready_jobs)
        _ -> :ok
      end

      result
    end
  end

  @doc """
  Revives a failed op by assigning it to a new ghost.

  Transitions: failed -> running. Unlike `reset`, this does NOT clean up
  the old shell/worktree — the new ghost reuses the existing worktree.
  """
  @spec revive(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def revive(op_id, ghost_id) do
    with {:ok, op} <- get(op_id),
         {:ok, next_status} <- validate_transition(op.status, :revive) do
      updated = %{op | status: next_status, ghost_id: ghost_id}
      Archive.put(:ops, updated)
    end
  end

  defp cleanup_bee_and_cell(nil), do: :ok

  defp cleanup_bee_and_cell(ghost_id) do
    # Stop the ghost worker process if running
    GiTF.Ghosts.stop(ghost_id)

    # Find and remove the ghost's active shell (worktree + branch)
    case Archive.find_one(:shells, fn c -> c.ghost_id == ghost_id and c.status == "active" end) do
      nil -> :ok
      shell -> GiTF.Shell.remove(shell.id, force: true)
    end

    # Mark ghost as stopped
    case GiTF.Ghosts.get(ghost_id) do
      {:ok, ghost} -> Archive.put(:ghosts, %{ghost | status: GhostStatus.stopped()})
      _ -> :ok
    end

    :ok
  end

  @doc """
  Kills a op: stops its ghost, removes its shell/worktree, deletes all
  dependencies, and removes the op record from the store.

  Returns `:ok` or `{:error, :not_found}`.
  """
  @spec kill(String.t()) :: :ok | {:error, :not_found}
  def kill(op_id) do
    case get(op_id) do
      {:ok, op} ->
        cleanup_bee_and_cell(op[:ghost_id])

        # Remove dependencies in both directions
        Archive.filter(:op_dependencies, fn d ->
          d.op_id == op_id or d.depends_on_id == op_id
        end)
        |> Enum.each(fn d -> Archive.delete(:op_dependencies, d.id) end)

        Archive.delete(:ops, op_id)
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Lists ops with optional filters.

  ## Options

    * `:mission_id` - filter by mission
    * `:status` - filter by status
    * `:ghost_id` - filter by assigned ghost
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    ops = Archive.all(:ops)

    ops =
      case Keyword.get(opts, :mission_id) do
        nil -> ops
        v -> Enum.filter(ops, &(Map.get(&1, :mission_id) == v))
      end

    ops =
      case Keyword.get(opts, :status) do
        nil -> ops
        v -> Enum.filter(ops, &(Map.get(&1, :status) == v))
      end

    ops =
      case Keyword.get(opts, :ghost_id) do
        nil -> ops
        v -> Enum.filter(ops, &(Map.get(&1, :ghost_id) == v))
      end

    Enum.sort_by(ops, & &1.inserted_at, {:desc, DateTime})
  end

  @doc """
  Gets a op by ID.

  Returns `{:ok, op}` or `{:error, :not_found}`.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(op_id) do
    Archive.fetch(:ops, op_id)
  end

  # -- Private helpers ---------------------------------------------------------

  defp transition(op_id, action) do
    with {:ok, op} <- get(op_id),
         {:ok, next_status} <- validate_transition(op.status, action) do
      updated = %{op | status: next_status}
      result = Archive.put(:ops, updated)

      case action do
        :start ->
          GiTF.Telemetry.emit([:gitf, :op, :started], %{}, %{
            op_id: op_id,
            mission_id: op.mission_id
          })

        :complete ->
          GiTF.Telemetry.emit([:gitf, :op, :completed], %{}, %{
            op_id: op_id,
            mission_id: op.mission_id
          })

        _ ->
          :ok
      end

      result
    end
  end

  defp validate_transition(current_status, action) do
    case Map.get(@transitions, {current_status, action}) do
      nil -> {:error, :invalid_transition}
      next -> {:ok, next}
    end
  end

  defp validate_required(attrs, keys) do
    missing =
      Enum.filter(keys, fn key ->
        val = attrs[key] || attrs[Atom.to_string(key)]
        is_nil(val) or val == ""
      end)

    if missing == [], do: :ok, else: {:error, {:missing_fields, missing}}
  end

  # -- Dependency management ---------------------------------------------------

  @doc """
  Adds a dependency: `op_id` depends on `depends_on_id`.

  Validates no self-dependency and no cycles (BFS).
  Returns `{:ok, dep}` or `{:error, reason}`.
  """
  @spec add_dependency(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def add_dependency(op_id, depends_on_id) do
    cond do
      op_id == depends_on_id ->
        {:error, :self_dependency}

      has_cycle?(op_id, depends_on_id) ->
        {:error, :cycle_detected}

      true ->
        record = %{op_id: op_id, depends_on_id: depends_on_id}
        result = Archive.insert(:op_dependencies, record)

        # Block the op if the dependency isn't resolved yet
        case get(depends_on_id) do
          {:ok, dep} when dep.status not in ["done", "failed", "rejected"] ->
            case get(op_id) do
              {:ok, %{status: "pending"}} -> block(op_id)
              _ -> :ok
            end
          _ -> :ok
        end

        result
    end
  end

  @doc "Removes a dependency between two ops."
  @spec remove_dependency(String.t(), String.t()) :: :ok | {:error, :not_found}
  def remove_dependency(op_id, depends_on_id) do
    case Archive.find_one(:op_dependencies, fn d ->
           d.op_id == op_id and d.depends_on_id == depends_on_id
         end) do
      nil ->
        {:error, :not_found}

      dep ->
        Archive.delete(:op_dependencies, dep.id)
        :ok
    end
  end

  @doc "Lists ops that `op_id` depends on."
  @spec dependencies(String.t()) :: [map()]
  def dependencies(op_id) do
    dep_ids =
      Archive.filter(:op_dependencies, fn d -> d.op_id == op_id end)
      |> Enum.map(& &1.depends_on_id)

    Enum.flat_map(dep_ids, fn id ->
      case Archive.get(:ops, id) do
        nil -> []
        op -> [op]
      end
    end)
  end

  @doc "Lists ops that depend on `op_id`."
  @spec dependents(String.t()) :: [map()]
  def dependents(op_id) do
    dep_op_ids =
      Archive.filter(:op_dependencies, fn d -> d.depends_on_id == op_id end)
      |> Enum.map(& &1.op_id)

    Enum.flat_map(dep_op_ids, fn id ->
      case Archive.get(:ops, id) do
        nil -> []
        op -> [op]
      end
    end)
  end

  @doc """
  Returns true if all dependencies of `op_id` are resolved.

  A dependency is resolved if:
  - The op is "done"
  - The op is "failed" (permanently — all retries exhausted or no retry created)
  - The op record no longer exists
  """
  @spec ready?(String.t()) :: boolean()
  def ready?(op_id) do
    deps = Archive.filter(:op_dependencies, fn d -> d.op_id == op_id end)

    Enum.all?(deps, fn dep ->
      case Archive.get(:ops, dep.depends_on_id) do
        nil -> true
        %{status: "done"} -> true
        %{status: s} when s in ["failed", "rejected"] ->
          # Dependency failed — check if a successful retry exists
          retry_completed?(dep.depends_on_id)
        _ -> false
      end
    end)
  end

  defp retry_completed?(op_id) do
    Archive.find_one(:ops, fn j ->
      Map.get(j, :retry_of) == op_id && j.status == "done"
    end) != nil
  end

  @doc """
  After a op completes or permanently fails, transitions blocked dependents
  to pending if all their dependencies are resolved (done or failed).

  If a dependency failed, appends failure context to the dependent's description
  so the ghost knows a prerequisite didn't complete.
  """
  @spec unblock_dependents(String.t()) :: :ok
  def unblock_dependents(op_id) do
    dependent_ids =
      Archive.filter(:op_dependencies, fn d -> d.depends_on_id == op_id end)
      |> Enum.map(& &1.op_id)

    # Check if this dependency failed (so we can warn dependents)
    dep_failed? =
      case get(op_id) do
        {:ok, %{status: s}} when s in ["failed", "rejected"] -> true
        _ -> false
      end

    Enum.each(dependent_ids, fn dep_op_id ->
      if ready?(dep_op_id) do
        case get(dep_op_id) do
          {:ok, %{status: "blocked"} = dep_job} ->
            # Inject failure context if a dependency failed
            if dep_failed? do
              warning = "\n\n## Warning: Dependency failed\n\nDependency op #{op_id} failed. " <>
                "Proceed with available context; the prerequisite work was not completed."
              updated = %{dep_job | description: (dep_job.description || "") <> warning}
              Archive.put(:ops, updated)
            end

            unblock(dep_op_id)

          _ ->
            :ok
        end
      end
    end)

    :ok
  end

  # -- Private helpers ---------------------------------------------------------

  # BFS cycle detection: adding depends_on_id as a dependency of op_id
  # would create a cycle if op_id is reachable from depends_on_id.
  defp has_cycle?(op_id, depends_on_id) do
    bfs_reachable?(depends_on_id, op_id, MapSet.new())
  end

  defp bfs_reachable?(from_id, target_id, visited) do
    if from_id == target_id do
      true
    else
      if MapSet.member?(visited, from_id) do
        false
      else
        visited = MapSet.put(visited, from_id)

        deps =
          Archive.filter(:op_dependencies, fn d -> d.op_id == from_id end)
          |> Enum.map(& &1.depends_on_id)

        Enum.any?(deps, fn dep_id -> bfs_reachable?(dep_id, target_id, visited) end)
      end
    end
  end
end
