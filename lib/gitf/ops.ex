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

  @max_retries 3
  require GiTF.Ghost.Status, as: GhostStatus

  # -- Valid transitions -------------------------------------------------------

  @transitions %{
    {"pending", :assign} => "assigned",
    # pending self-transitions exist so recovery can operate on ops stranded
    # pending with a stale ghost assignment (crashed ghost, unclean
    # shutdown): reset clears the assignment, fail lets watchdogs time such
    # ops out. Without them, both manual `op reset` (422) and the
    # timeout_stale_jobs janitor were no-ops on exactly the stuck shape.
    {"pending", :reset} => "pending",
    {"pending", :fail} => "failed",
    {"assigned", :start} => "running",
    {"assigned", :reset} => "pending",
    {"assigned", :fail} => "failed",
    {"running", :reset} => "pending",
    {"running", :complete} => "done",
    {"running", :fail} => "failed",
    {"done", :reject} => "rejected",
    {"failed", :reset} => "pending",
    {"rejected", :reset} => "pending",
    {"failed", :revive} => "running",
    # Legacy: older releases wrote status "killed" (kill now deletes the
    # record); without this those records are un-resettable forever.
    {"killed", :reset} => "pending",
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
        strategy: attrs[:strategy],
        # Tournament variant (nil for single-variant missions; "v1"/"v2"/...
        # when GiTF.Tournament.enabled? duplicated this op across parallel
        # implementation branches).
        variant: attrs[:variant],
        acceptance_criteria: attrs[:acceptance_criteria] || [],
        target_files: attrs[:target_files] || [],
        # Audit fields
        verification_status: "pending",
        audit_result: nil,
        verified_at: nil,
        # Risk level for adaptive permissions (always normalized to atom)
        risk_level: normalize_risk(classification[:risk_level] || attrs[:risk_level] || :low),
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
        skip_verification: attrs[:skip_verification] || false,
        # Fix-loop lineage. Dropping these orphaned every fix op: a gate
        # failure on a COMPLETED fix op found no context, spawned a fresh
        # "attempt 1" fix-of-fix, and the chain never accumulated toward
        # exhausted?/1 — the unbounded loop that ate runs 3, 5, and 6
        # (finding #14).
        fix_of: attrs[:fix_of],
        fix_context: attrs[:fix_context],
        # Set on focused merge-resolution ops (the branch being reconciled,
        # or "worktree" for leftover markers) so consolidation can count
        # attempts per target instead of guessing from titles.
        conflict_resolution: attrs[:conflict_resolution],
        # Priority (inherited from mission)
        priority: attrs[:priority] || inherit_mission_priority(attrs[:mission_id])
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
    Archive.update(:ops, op_id, fn op ->
      case validate_transition(op.status, :assign) do
        {:ok, next_status} ->
          {:ok, %{op | status: next_status, ghost_id: ghost_id}}

        {:error, _} = err ->
          err
      end
    end)
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

  # NOTE: `create_retry/2` was deleted here (2026-08-26). It had zero
  # callers — the live retry path is `reset/2`, which reuses the op in place
  # so its :op_dependencies rows survive — and it copied an op WITHOUT its
  # dependency edges. If it had ever gained a caller, a retried chain op
  # would have bypassed the planner's same-file serialization guarantee,
  # which is the exact hole that produced msn-8e0eae's conflict markers.
  # Reintroduce only with edge mirroring (see Intel.Retry.retry_job, which
  # learned this lesson in run 22).

  @doc """
  Resets a failed op back to pending so it can be retried.

  Transitions: failed -> pending. Also stops the assigned ghost,
  cleans up its shell/worktree, and clears the ghost_id assignment
  so the op can be assigned to a fresh ghost.

  Optionally appends feedback to the op description.
  """
  @spec reset(String.t(), String.t() | nil) :: {:ok, map()} | {:error, atom()}
  def reset(op_id, feedback \\ nil) do
    # Peek to capture ghost_id for cleanup (cleanup has side effects on
    # other collections — kept outside the atomic op update).
    case get(op_id) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:ok, %{ghost_id: ghost_id}} ->
        result =
          Archive.update(:ops, op_id, fn op ->
            case validate_transition(op.status, :reset) do
              {:ok, next_status} ->
                new_description =
                  if feedback do
                    (op.description || "") <>
                      "\n\n## Feedback from previous attempt:\n\n" <> feedback
                  else
                    op.description
                  end

                retry_count = Map.get(op, :retry_count, 0) + 1

                {:ok,
                 %{
                   op
                   | status: next_status,
                     ghost_id: nil,
                     retry_count: retry_count,
                     description: new_description
                 }}

              {:error, _} = err ->
                err
            end
          end)

        case result do
          {:ok, _} ->
            # Cleanup only after the transition is accepted — it deletes the
            # ghost's shell/worktree (and any partial work on its branch), so
            # running it before validation destroyed work on every refused
            # reset attempt.
            cleanup_ghost_and_shell(ghost_id)

            # Nudge Major's spawner so the reset op gets picked up immediately
            case Process.whereis(GiTF.Major) do
              pid when is_pid(pid) -> send(pid, :spawn_ready_jobs)
              _ -> :ok
            end

          _ ->
            :ok
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
    Archive.update(:ops, op_id, fn op ->
      case validate_transition(op.status, :revive) do
        {:ok, next_status} -> {:ok, %{op | status: next_status, ghost_id: ghost_id}}
        {:error, _} = err -> err
      end
    end)
  end

  defp cleanup_ghost_and_shell(nil), do: :ok

  defp cleanup_ghost_and_shell(ghost_id) do
    # Stop the ghost worker process if running
    GiTF.Ghosts.stop(ghost_id)

    # Find and remove the ghost's active shell (worktree + branch)
    case Archive.find_one(:shells, fn c -> c.ghost_id == ghost_id and c.status == "active" end) do
      nil -> :ok
      shell -> GiTF.Shell.remove(shell.id, force: true)
    end

    # Mark ghost as stopped atomically
    Archive.update(:ghosts, ghost_id, fn ghost ->
      %{ghost | status: GhostStatus.stopped()}
    end)

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
        cleanup_ghost_and_shell(op[:ghost_id])

        # Remove dependencies in both directions
        (Archive.by_index(:op_dependencies, :op_id, op_id) ++
           Archive.by_index(:op_dependencies, :depends_on_id, op_id))
        |> Enum.uniq_by(& &1.id)
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
  Is a fix op (quality-gate or validation lane) already pending or running
  for this mission?

  Fix ghosts must run ONE AT A TIME in the single consolidated worktree
  lineage: run 14 (msn-a5ddd6) had the validation lane fully reconcile the
  merged tree on its branch while the quality lane concurrently built a
  competing marker-laden lineage — target selection then picked the wrong
  one and the mission burned its whole fix budget on work that was already
  done. Callers skip creating a new fix op while one is in flight; the next
  validation/quality round re-derives whatever remains.
  """
  @spec fix_in_flight?(String.t()) :: boolean()
  def fix_in_flight?(mission_id) do
    active_non_phase_op?(mission_id, &is_binary(&1[:fix_of]))
  end

  @doc """
  Is ANY non-phase op (implementation chain or fix, either lane) pending or
  running for this mission?

  Fix creation must gate on this, not just on other fixes: a quality-gate
  fix spawned while the NEXT chain op was already running forked a sibling
  branch off the completed tip — a permanent divergence that re-conflicted
  at every consolidation and GREW the marker set each round (run 15:
  6 → 8 conflicted files across attempts). One worktree-writing ghost at a
  time is the invariant; deferred quality issues are re-derived by the next
  gate or validation round.
  """
  @spec worktree_writer_in_flight?(String.t()) :: boolean()
  def worktree_writer_in_flight?(mission_id) do
    active_non_phase_op?(mission_id, fn _ -> true end)
  end

  defp active_non_phase_op?(mission_id, extra_filter) do
    Archive.by_index(:ops, :mission_id, mission_id)
    |> Enum.any?(fn op ->
      op[:phase_job] not in [true] and
        op.status in ["pending", "assigned", "running"] and
        extra_filter.(op)
    end)
  rescue
    _ ->
      GiTF.Archive.filter(:ops, fn op ->
        op[:mission_id] == mission_id and op[:phase_job] not in [true] and
          op.status in ["pending", "assigned", "running"] and extra_filter.(op)
      end) != []
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
    result =
      Archive.update(:ops, op_id, fn op ->
        case validate_transition(op.status, action) do
          {:ok, next_status} ->
            transitioned = op.status != next_status
            {:ok, %{op | status: next_status}, %{transitioned: transitioned}}

          {:error, _} = err ->
            err
        end
      end)

    # Emit telemetry after the atomic write — only on a real transition.
    case {action, result} do
      {:start, {:ok, op, %{transitioned: true}}} ->
        GiTF.Telemetry.emit([:gitf, :op, :started], %{}, %{
          op_id: op_id,
          mission_id: op.mission_id
        })

      {:complete, {:ok, op, %{transitioned: true}}} ->
        GiTF.Telemetry.emit([:gitf, :op, :completed], %{}, %{
          op_id: op_id,
          mission_id: op.mission_id
        })

      _ ->
        :ok
    end

    # Preserve the historical public contract: {:ok, op} | {:error, reason}
    case result do
      {:ok, op, _meta} -> {:ok, op}
      other -> other
    end
  end

  defp validate_transition(current_status, action) do
    case Map.get(@transitions, {current_status, action}) do
      nil -> {:error, :invalid_transition}
      next -> {:ok, next}
    end
  end

  defp inherit_mission_priority(nil), do: :normal

  defp inherit_mission_priority(mission_id) do
    case GiTF.Archive.get(:missions, mission_id) do
      %{priority: p} when is_atom(p) -> p
      _ -> :normal
    end
  rescue
    e ->
      require Logger

      Logger.warning(
        "inherit_mission_priority failed for mission #{mission_id}: #{Exception.message(e)}",
        mission_id: mission_id
      )

      :normal
  end

  defp normalize_risk(level) when is_atom(level), do: level
  defp normalize_risk("low"), do: :low
  defp normalize_risk("medium"), do: :medium
  defp normalize_risk("high"), do: :high
  defp normalize_risk("critical"), do: :critical
  defp normalize_risk(_), do: :low

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

          _ ->
            :ok
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
      Archive.by_index(:op_dependencies, :op_id, op_id)
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
      Archive.by_index(:op_dependencies, :depends_on_id, op_id)
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
    deps = Archive.by_index(:op_dependencies, :op_id, op_id)

    Enum.all?(deps, fn dep ->
      case Archive.get(:ops, dep.depends_on_id) do
        nil ->
          true

        %{status: "done"} ->
          true

        %{status: s} when s in ["failed", "rejected"] ->
          retry_completed?(dep.depends_on_id)

        _ ->
          false
      end
    end)
  end

  @doc """
  Batch variant of `ready?/1` for hot-path scheduling.

  Takes pre-loaded dependencies grouped by op_id and an ops-by-id map to
  avoid per-op Archive scans. Used by the scheduler to check readiness
  for many ops in a single pass.
  """
  @spec ready?(String.t(), %{optional(String.t()) => [map()]}, %{optional(String.t()) => map()}) ::
          boolean()
  def ready?(op_id, deps_by_op, ops_by_id) do
    deps = Map.get(deps_by_op, op_id, [])

    Enum.all?(deps, fn dep ->
      case Map.get(ops_by_id, dep.depends_on_id) do
        nil ->
          true

        %{status: "done"} ->
          true

        %{status: s} when s in ["failed", "rejected"] ->
          retry_completed_in?(dep.depends_on_id, ops_by_id)

        _ ->
          false
      end
    end)
  end

  @doc "Returns the max retry count an op may accumulate before exhausting."
  @spec max_retries() :: pos_integer()
  def max_retries, do: @max_retries

  # Retry chains can be MORE than one generation: original → retry →
  # retry-of-retry. Checking only direct children stalled msn-6be1ba for
  # 72 minutes — the bindings op failed, its retry failed, the third
  # sibling succeeded, and seven dependents stayed blocked because their
  # edges point at the ORIGINAL id and nothing walked the chain.
  @max_retry_chain_depth 10

  @doc """
  Returns true if any DESCENDANT in `op_id`'s retry chain (retry, retry of
  retry, …) reached `\"done\"`.
  Touches Archive — use `retry_completed_in?/2` when iterating in a loop.
  """
  @spec retry_completed?(String.t()) :: boolean()
  def retry_completed?(op_id), do: descendant_done?(op_id, 0)

  defp descendant_done?(_op_id, depth) when depth >= @max_retry_chain_depth, do: false

  defp descendant_done?(op_id, depth) do
    Archive.filter(:ops, fn j -> Map.get(j, :retry_of) == op_id end)
    |> Enum.any?(fn j -> j.status == "done" or descendant_done?(j.id, depth + 1) end)
  end

  @doc """
  The `\"done\"` op that resolves `op_id`'s retry chain, or nil.

  Used wherever a consumer needs the RESOLVING op itself rather than a
  boolean — e.g. worktree chain-inheritance, where a dependent op must
  continue in the worktree of whichever descendant actually finished.
  """
  @spec done_retry_descendant(String.t(), non_neg_integer()) :: map() | nil
  def done_retry_descendant(op_id, depth \\ 0)
  def done_retry_descendant(_op_id, depth) when depth >= @max_retry_chain_depth, do: nil

  def done_retry_descendant(op_id, depth) do
    children = Archive.filter(:ops, fn j -> Map.get(j, :retry_of) == op_id end)

    Enum.find(children, &(&1.status == "done")) ||
      Enum.find_value(children, &done_retry_descendant(&1.id, depth + 1))
  end

  @doc """
  In-memory variant of `retry_completed?/1` — accepts any enumerable of
  ops (list or `{id, op}` map entries). Use when checking many ops in a
  single pass to avoid N Archive scans. Traverses the whole retry chain,
  like `retry_completed?/1`.
  """
  @spec retry_completed_in?(String.t(), Enumerable.t()) :: boolean()
  def retry_completed_in?(op_id, ops) do
    ops
    |> Enum.map(fn
      {_id, op} -> op
      op when is_map(op) -> op
    end)
    |> descendant_done_in?(op_id, 0)
  end

  defp descendant_done_in?(_ops, _op_id, depth) when depth >= @max_retry_chain_depth, do: false

  defp descendant_done_in?(ops, op_id, depth) do
    ops
    |> Enum.filter(&(Map.get(&1, :retry_of) == op_id))
    |> Enum.any?(fn op ->
      op.status == "done" or descendant_done_in?(ops, op.id, depth + 1)
    end)
  end

  @doc """
  Returns true if a failed op still has retry budget AND no retry has
  spawned yet (delayed_retry timer pending).
  """
  @spec retry_pending?(map()) :: boolean()
  def retry_pending?(op) do
    (Map.get(op, :retry_count, 0) || 0) < @max_retries and is_nil(Map.get(op, :retried_as))
  end

  @doc """
  Returns true if `op` is in a terminal-resolved state — either done, or
  failed but a sibling op with `retry_of: op.id` reached `\"done\"`.

  Hot loops should pre-build a MapSet of resolved-via-retry op IDs once
  via `retried_ok_set/1` and pass it as `retried_ok`. Without it the
  function falls back to a full Archive scan per failed op.
  """
  @spec resolved?(map(), MapSet.t() | nil) :: boolean()
  def resolved?(op, retried_ok \\ nil)

  def resolved?(%{status: "done"}, _retried_ok), do: true

  def resolved?(%{status: s} = op, %MapSet{} = retried_ok)
      when s in ["failed", "rejected", "killed"] do
    MapSet.member?(retried_ok, op.id)
  end

  def resolved?(%{status: s} = op, nil) when s in ["failed", "rejected", "killed"] do
    retry_completed?(op.id)
  end

  def resolved?(_op, _retried_ok), do: false

  @doc """
  Builds a MapSet of op IDs resolved by a `\"done\"` op somewhere in their
  retry DESCENDANT chain. A completed retry-of-a-retry resolves its whole
  ancestor line, since dependency edges point at the original op's id.
  Pass to `resolved?/2` to avoid O(n²) sibling scans in loops.
  """
  @spec retried_ok_set(Enumerable.t()) :: MapSet.t()
  def retried_ok_set(ops) do
    by_id = Map.new(ops, &{&1.id, &1})

    for o <- ops,
        o.status == "done",
        id = Map.get(o, :retry_of),
        not is_nil(id),
        reduce: MapSet.new() do
      acc -> put_retry_ancestors(id, by_id, acc, 0)
    end
  end

  defp put_retry_ancestors(nil, _by_id, acc, _depth), do: acc
  defp put_retry_ancestors(_id, _by_id, acc, depth) when depth >= @max_retry_chain_depth, do: acc

  defp put_retry_ancestors(id, by_id, acc, depth) do
    if MapSet.member?(acc, id) do
      acc
    else
      acc = MapSet.put(acc, id)

      case Map.get(by_id, id) do
        %{} = op -> put_retry_ancestors(Map.get(op, :retry_of), by_id, acc, depth + 1)
        _ -> acc
      end
    end
  end

  @doc """
  After a op completes or permanently fails, transitions blocked dependents
  to pending if all their dependencies are resolved (done or failed).

  If a dependency failed, appends failure context to the dependent's description
  so the ghost knows a prerequisite didn't complete.
  """
  @spec unblock_dependents(String.t()) :: :ok
  def unblock_dependents(op_id) do
    unblock_dependents(op_id, 0)
  end

  @max_unblock_retries 3
  @unblock_retry_delay_ms 1_000

  @spec unblock_dependents(String.t(), non_neg_integer()) :: :ok
  def unblock_dependents(op_id, attempt) do
    # A completing RETRY satisfies its whole ancestor chain's dependents:
    # dependency edges point at the planner's ORIGINAL op id, while the op
    # that finally succeeds may be a retry-of-a-retry. Without walking up,
    # those dependents wait for the Tachikoma patrol at best — msn-6be1ba
    # sat blocked for 72 minutes at worst.
    op_id
    |> retry_ancestor_ids()
    |> Enum.each(&unblock_dependents_of(&1, attempt))
  end

  defp retry_ancestor_ids(op_id), do: collect_retry_ancestors(op_id, [], 0)

  defp collect_retry_ancestors(nil, acc, _depth), do: Enum.reverse(acc)

  defp collect_retry_ancestors(op_id, acc, depth) when depth >= @max_retry_chain_depth,
    do: Enum.reverse([op_id | acc])

  defp collect_retry_ancestors(op_id, acc, depth) do
    if op_id in acc do
      Enum.reverse(acc)
    else
      parent =
        case Archive.get(:ops, op_id) do
          %{} = op -> Map.get(op, :retry_of)
          _ -> nil
        end

      collect_retry_ancestors(parent, [op_id | acc], depth + 1)
    end
  end

  defp unblock_dependents_of(op_id, attempt) do
    # Serialize concurrent calls for the same op so multiple code paths
    # (link_received handler, retry, phase advance) don't duplicate work.
    # If another caller holds the lock but then crashes before finishing,
    # dependents would stay blocked forever — so on contention, schedule a
    # bounded async retry instead of silently skipping.
    result =
      GiTF.MissionLock.with_lock(
        {:unblock_dependents, op_id},
        [on_contention: :error],
        fn -> do_unblock_dependents(op_id) end
      )

    case result do
      {:error, :locked} when attempt < @max_unblock_retries ->
        Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
          Process.sleep(@unblock_retry_delay_ms)
          # Retry only THIS id — the sibling ancestors already ran (or are
          # running their own retries); re-expanding the chain here would
          # multiply lock attempts.
          unblock_dependents_of(op_id, attempt + 1)
        end)

        :ok

      {:error, :locked} ->
        require Logger

        Logger.warning(
          "unblock_dependents(#{op_id}): lock contention persisted past #{@max_unblock_retries} retries; dependents may remain blocked"
        )

        :ok

      _ ->
        :ok
    end
  end

  defp do_unblock_dependents(op_id) do
    dependent_ids =
      Archive.by_index(:op_dependencies, :depends_on_id, op_id)
      |> Enum.map(& &1.op_id)

    dep_failed? =
      case get(op_id) do
        {:ok, %{status: s}} when s in ["failed", "rejected"] -> true
        _ -> false
      end

    Enum.each(dependent_ids, fn dep_op_id ->
      if ready?(dep_op_id) do
        case get(dep_op_id) do
          {:ok, %{status: "blocked"} = dep_job} ->
            if dep_failed? do
              warning =
                "\n\n## Warning: Dependency failed\n\nDependency op #{op_id} failed. " <>
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
          Archive.by_index(:op_dependencies, :op_id, from_id)
          |> Enum.map(& &1.depends_on_id)

        Enum.any?(deps, fn dep_id -> bfs_reachable?(dep_id, target_id, visited) end)
      end
    end
  end
end
