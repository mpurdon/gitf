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

  # A mission nobody will do anything more with. `closed` and `killed` belong
  # here as much as `completed`: an operator ending a mission ends it. Leaving
  # them out made every closed mission look like live work forever, which kept
  # the idle-stop timer from ever firing and pinned the box awake.
  @finished_statuses [nil | ~w(completed failed cancelled closed killed)]

  # Paused missions are finished with the FACTORY but not with the operator —
  # they still show up in operator views, and still let the box sleep.
  @paused_statuses ~w(paused paused_budget)

  @doc "True when the mission will see no further work from anyone."
  @spec finished?(map()) :: boolean()
  def finished?(mission), do: Map.get(mission, :status) in @finished_statuses

  # Broader than @active_statuses: also covers queued/awaiting_approval etc.
  # "Non-terminal" means the mission still wants the factory — the notion
  # liveness and idle-stop decisions need.
  @doc "True when the mission is not in a terminal or paused state."
  @spec non_terminal?(map()) :: boolean()
  def non_terminal?(mission),
    do: not finished?(mission) and Map.get(mission, :status) not in @paused_statuses

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

      explicit_issue_ref = attrs[:issue_ref] || attrs["issue_ref"]
      issue_ref = explicit_issue_ref || parse_issue_ref(goal)

      sector_id = attrs[:sector_id] || attrs["sector_id"]
      explicit_workflow = attrs[:workflow_id] || attrs["workflow_id"]

      {workflow_id, inference_meta} =
        resolve_workflow_with_inference(explicit_workflow, sector_id, goal)

      artifacts = if inference_meta, do: %{"workflow_inference" => inference_meta}, else: %{}

      record = %{
        name: name,
        goal: goal,
        status: attrs[:status] || "pending",
        sector_id: sector_id,
        current_phase: "pending",
        phase_advance_seq: 0,
        priority: priority,
        priority_source: priority_source,
        priority_set_at: DateTime.utc_now(),
        review_plan: attrs[:review_plan] || attrs["review_plan"] || false,
        research_summary: nil,
        implementation_plan: nil,
        artifacts: artifacts,
        phase_jobs: %{},
        issue_ref: issue_ref,
        cost_cap_usd: attrs[:cost_cap_usd] || attrs["cost_cap_usd"],
        workflow_id: workflow_id,
        # Provenance for Aramaki (the admission layer). `source` identifies the
        # intake channel (e.g. "github_issue"); `source_issue` carries the
        # linkage used to report progress back; `aramaki_priority` orders the
        # admission queue. All nil for operator-created missions.
        source: attrs[:source] || attrs["source"],
        source_issue: attrs[:source_issue] || attrs["source_issue"],
        # Set when a mission amends work that is already on a branch (a
        # follow-up from PR review feedback). Sync builds on this branch
        # instead of cutting a new one off main, so the open PR for that
        # head updates in place rather than a second PR appearing.
        target_branch: attrs[:target_branch] || attrs["target_branch"],
        # For project-sourced missions: %{project_id, item_id} linking back to
        # the roadmap item this mission executes.
        source_project: attrs[:source_project] || attrs["source_project"],
        aramaki_priority: attrs[:aramaki_priority] || attrs["aramaki_priority"],
        # Tournament fields — `impl_variants` is set by the implementation
        # phase when GiTF.Tournament.enabled? to the list of variant ids
        # (`["v1", "v2", ...]`) the mission is running in parallel.
        # `winning_variant` is stamped by Phases.Validation after the
        # tournament completes. Both stay nil for single-variant missions.
        impl_variants: [],
        winning_variant: nil
      }

      case Archive.insert(:missions, record) do
        {:ok, mission} = result ->
          GiTF.Telemetry.emit([:gitf, :mission, :created], %{}, %{
            mission_id: mission.id,
            name: name,
            priority: priority,
            priority_source: priority_source
          })

          if is_nil(explicit_workflow) and GiTF.Workflow.Inference.enabled?() and is_binary(goal) do
            schedule_inference_for(mission, goal)
          end

          result

        error ->
          error
      end
    end
  end

  @doc """
  Extracts a structured GitHub issue reference from free-form text.

  Recognised formats (first match wins):

    * `owner/repo#123` → `%{owner: "owner", repo: "repo", number: 123}`
    * `GH-123` or `gh-123` → `%{number: 123}` (bare, repo unknown)
    * `#123` → `%{number: 123}` (bare)
    * `https://github.com/<owner>/<repo>/issues/<n>` → fully qualified

  Returns `nil` when no recognised reference is present.
  """
  @spec parse_issue_ref(String.t() | nil) :: map() | nil
  def parse_issue_ref(nil), do: nil

  def parse_issue_ref(text) when is_binary(text) do
    cond do
      match = Regex.run(~r{https?://github\.com/([\w.-]+)/([\w.-]+)/(?:issues|pull)/(\d+)}, text) ->
        [_, owner, repo, n] = match
        %{"owner" => owner, "repo" => repo, "number" => String.to_integer(n)}

      match = Regex.run(~r/\b([\w.-]+)\/([\w.-]+)#(\d+)\b/, text) ->
        [_, owner, repo, n] = match
        %{"owner" => owner, "repo" => repo, "number" => String.to_integer(n)}

      match = Regex.run(~r/\b(?:GH|gh)-(\d+)\b/, text) ->
        [_, n] = match
        %{"number" => String.to_integer(n)}

      match = Regex.run(~r/(?:^|\s)#(\d+)\b/, text) ->
        [_, n] = match
        %{"number" => String.to_integer(n)}

      true ->
        nil
    end
  end

  def parse_issue_ref(_), do: nil

  @doc """
  Finds missions already tracking the same issue reference (same sector
  and same issue number). Used to guard against duplicate missions when
  an issue triggers a fresh mission via webhook or repeated CLI.

  Excludes missions in terminal `"failed"` / `"closed"` status by default.
  """
  @spec find_by_issue_ref(String.t() | nil, map()) :: [map()]
  def find_by_issue_ref(_sector_id, nil), do: []
  def find_by_issue_ref(_sector_id, ref) when not is_map(ref), do: []

  def find_by_issue_ref(sector_id, %{"number" => n} = ref) do
    Archive.filter(:missions, fn m ->
      m[:sector_id] == sector_id and
        match?(%{"number" => ^n}, m[:issue_ref]) and
        match_issue_owner_repo?(m[:issue_ref], ref) and
        m[:status] not in ["failed", "closed"]
    end)
  end

  def find_by_issue_ref(_sector_id, _), do: []

  defp match_issue_owner_repo?(
         %{"owner" => o1, "repo" => r1},
         %{"owner" => o2, "repo" => r2}
       ) do
    o1 == o2 and r1 == r2
  end

  # When either side lacks owner/repo, match by number alone — the bare
  # "GH-123" / "#123" form can't be disambiguated across repos, so treat
  # it as a match within the same sector.
  defp match_issue_owner_repo?(existing, _ref) when is_map(existing), do: true
  defp match_issue_owner_repo?(_, _), do: false

  @doc """
  Switches a running mission to a different workflow. The mission's
  `current_phase` is preserved — the new workflow takes effect on the
  next phase advance. Errors when the target workflow can't be loaded
  or is incompatible (M3 just persists the field; orchestrator
  integration is M3-B).
  """
  @spec switch_workflow(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def switch_workflow(mission_id, workflow_name) when is_binary(workflow_name) do
    mission = Archive.get(:missions, mission_id)

    if is_nil(mission) do
      {:error, :mission_not_found}
    else
      case GiTF.Workflow.resolve(workflow_name, mission[:sector_id]) do
        {:ok, _w} ->
          Archive.update(:missions, mission_id, fn m ->
            Map.put(m, :workflow_id, workflow_name)
          end)

        {:error, _} = err ->
          err
      end
    end
  end

  # Resolution order:
  #   explicit attr → AI classifier (if enabled) → sector default → "standard"
  #
  # Returns `{workflow_id, inference_meta}` where inference_meta is a
  # map persisted under `mission.artifacts.workflow_inference` (or nil
  # when the classifier wasn't consulted).
  defp resolve_workflow_with_inference(explicit, _sector_id, _goal)
       when is_binary(explicit) and explicit != "" do
    {explicit, nil}
  end

  # Inference is potentially-slow LLM work; we don't block mission
  # create on it. The mission ships immediately on the sector default,
  # then `schedule_inference_for/2` runs the classifier in a Task and
  # updates `workflow_id` + `artifacts.workflow_inference` if it
  # comes back confident. Tests can disable async by setting
  # `:workflow_inference_async` to `false`.
  defp resolve_workflow_with_inference(_explicit, sector_id, _goal) do
    {sector_default_workflow(sector_id), nil}
  end

  defp schedule_inference_for(mission, goal) do
    if Application.get_env(:gitf, :workflow_inference_async, true) do
      Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
        run_inference(mission, goal)
      end)

      :ok
    else
      run_inference(mission, goal)
    end
  end

  defp run_inference(mission, goal) do
    case GiTF.Workflow.Inference.classify(goal) do
      {:ok, name, confidence, rationale} ->
        meta = %{
          "classifier" => "auto",
          "selected" => name,
          "confidence" => confidence,
          "rationale" => rationale,
          "at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

        Archive.update(:missions, mission.id, fn m ->
          artifacts = Map.put(m[:artifacts] || %{}, "workflow_inference", meta)
          m |> Map.put(:artifacts, artifacts) |> Map.put(:workflow_id, name)
        end)

      :no_match ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # Kept for backward compatibility with any direct callers.
  @doc false
  def resolve_workflow_id(attrs, sector_id) do
    cond do
      is_binary(attrs[:workflow_id]) -> attrs[:workflow_id]
      is_binary(attrs["workflow_id"]) -> attrs["workflow_id"]
      true -> sector_default_workflow(sector_id)
    end
  end

  defp sector_default_workflow(nil), do: "standard"

  defp sector_default_workflow(sector_id) do
    case Archive.get(:sectors, sector_id) do
      %{default_workflow: w} when is_binary(w) and w != "" -> w
      _ -> "standard"
    end
  end

  defp generate_name(goal) do
    slug =
      goal
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s-]/, "")
      |> String.trim()
      |> String.replace(~r/\s+/, "-")

    # Truncate on a word boundary — slicing first produced branch names like
    # "sort-the-user-list-case-insensitively-currently-u".
    if String.length(slug) <= 50 do
      slug
    else
      slug
      |> String.slice(0, 50)
      |> String.replace(~r/-[^-]*$/, "")
    end
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
    Archive.update(:missions, mission_id, fn mission -> Map.merge(mission, attrs) end)
  end

  @doc """
  Unconditionally marks a mission as completed.

  Unlike `transition_phase/3` and `update_status!/1`, this bypasses the
  "terminal failed" guard — the orchestrator calls this only after
  confirming real completion (validation passed + sync merged), so
  recovering from a transient `fail_quest` is both safe and desirable.

  Without this recovery path, an intermediate fix-op crash that fired
  `fail_quest` would leave the mission permanently "failed" even when
  subsequent fix attempts succeeded and the work was merged to sector
  main.
  """
  @spec complete_quest(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def complete_quest(mission_id, reason \\ nil) do
    case Archive.get(:missions, mission_id) do
      nil ->
        {:error, :not_found}

      mission ->
        from_phase = Map.get(mission, :current_phase, "pending")

        if !recent_duplicate_transition?(mission_id, from_phase, "completed") do
          Archive.insert(:mission_phase_transitions, %{
            mission_id: mission_id,
            from_phase: from_phase,
            to_phase: "completed",
            reason: reason,
            seq: System.monotonic_time(:microsecond)
          })

          GiTF.EventStore.record(:phase_transition, mission_id, %{
            from: from_phase,
            to: "completed",
            reason: reason,
            outcome: "completed"
          })
        end

        result =
          Archive.update(:missions, mission_id, fn m ->
            m
            |> Map.put(:current_phase, "completed")
            |> Map.put(:status, "completed")
            |> Map.delete(:failure_reason)
          end)

        # Report back on the source GitHub issue (no-op for non-issue missions).
        notify_aramaki_terminal(mission, :completed)
        result
    end
  end

  # Best-effort Aramaki notification on a terminal mission state. GitHub-issue
  # missions report back to their issue; project missions advance their
  # roadmap item (and unblock dependents / pause the project on failure).
  #
  # Called from BOTH terminal paths — `complete_quest`/`fail_quest` (legacy,
  # fast-path, no-work) and `mark_user_visible_completed` (standard workflow,
  # where complete_quest never runs — see Phases.Scoring.terminal). The
  # `aramaki_notified` flag dedupes missions that traverse both.
  defp notify_aramaki_terminal(mission, outcome) do
    source = Map.get(mission, :source)

    if source in ["github_issue", "project"] and !Map.get(mission, :aramaki_notified, false) do
      Archive.update(:missions, mission.id, &Map.put(&1, :aramaki_notified, true))

      case source do
        "github_issue" ->
          case outcome do
            :completed -> GiTF.Aramaki.Lifecycle.on_merged(mission)
            {:failed, reason} -> GiTF.Aramaki.Lifecycle.on_failed(mission, reason || "unknown")
          end

        "project" ->
          GiTF.Project.on_mission_terminal(mission, outcome)
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Marks a mission user-visibly complete while post-processing (scoring +
  learning) continues in the background.

  Sets `status = "completed"` (terminal, user-facing) and
  `post_processing_status = "pending"`. `current_phase` is NOT advanced —
  the orchestrator keeps driving scoring via the normal phase pipeline
  until `mark_post_processing_done/1` flips the phase to "completed".

  The terminal-state guard in `update_status!/1` protects the completed
  status from regression while scoring runs.
  """
  @spec mark_user_visible_completed(String.t()) :: {:ok, map()} | {:error, term()}
  def mark_user_visible_completed(mission_id) do
    result =
      Archive.update(:missions, mission_id, fn m ->
        m
        |> Map.put(:status, "completed")
        |> Map.put(:post_processing_status, "pending")
        |> Map.delete(:failure_reason)
      end)

    # This is the terminal moment on the standard workflow path (complete_quest
    # never runs there) — report to Aramaki now so issue-sourced missions close
    # their issue and project missions unblock their roadmap dependents.
    with {:ok, mission} <- result do
      notify_aramaki_terminal(mission, :completed)
    end

    result
  end

  @doc """
  Marks post-processing (async scoring + learning) as finished.

  Advances `current_phase` to "completed" and sets
  `post_processing_status = "done"`. The user-visible `status` field is
  already "completed" at this point (set by `mark_user_visible_completed/1`).
  """
  @spec mark_post_processing_done(String.t()) :: {:ok, map()} | {:error, term()}
  def mark_post_processing_done(mission_id) do
    with_post_processing_transition(mission_id, "post-processing complete", "completed", fn m ->
      m
      |> Map.put(:current_phase, "completed")
      |> Map.put(:status, "completed")
      |> Map.put(:post_processing_status, "done")
      |> Map.delete(:failure_reason)
    end)
  end

  @doc """
  Marks post-processing as failed without regressing the user-visible
  "completed" status. `current_phase` advances to "completed" so the
  mission isn't stuck in scoring forever.
  """
  @spec mark_post_processing_failed(String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def mark_post_processing_failed(mission_id, reason \\ nil) do
    with_post_processing_transition(
      mission_id,
      reason || "post-processing failed",
      "failed",
      fn m ->
        m
        |> Map.put(:current_phase, "completed")
        |> Map.put(:status, "completed")
        |> Map.put(:post_processing_status, "failed")
      end
    )
  end

  # Records the "→ completed" phase transition (best-effort, append-only,
  # deduped if an identical transition landed recently) and then applies
  # `updater` to the mission record. The phase_transitions log is outside
  # the Archive.update closure by design: it's an append-only event feed,
  # not part of the mission's canonical state.
  defp with_post_processing_transition(mission_id, reason, outcome, updater) do
    case Archive.get(:missions, mission_id) do
      nil ->
        {:error, :not_found}

      mission ->
        from_phase = Map.get(mission, :current_phase, "pending")

        if from_phase != "completed" and
             !recent_duplicate_transition?(mission_id, from_phase, "completed") do
          Archive.insert(:mission_phase_transitions, %{
            mission_id: mission_id,
            from_phase: from_phase,
            to_phase: "completed",
            reason: reason,
            seq: System.monotonic_time(:microsecond)
          })

          GiTF.EventStore.record(:phase_transition, mission_id, %{
            from: from_phase,
            to: "completed",
            reason: reason,
            outcome: outcome
          })
        end

        Archive.update(:missions, mission_id, updater)
    end
  end

  @doc """
  Atomically marks a mission as failed.

  Sets `current_phase = "completed"` AND `status = "failed"` in a single
  Archive.update/3 closure so a crash between the two writes cannot leave
  the mission in an inconsistent state. Also records a phase_transition
  event (best-effort, outside the record lock).

  Returns `{:ok, mission}` or `{:error, :not_found}`.
  """
  @spec fail_quest(String.t(), String.t() | nil) :: {:ok, map()} | {:error, :not_found}
  def fail_quest(mission_id, reason \\ nil) do
    # Best-effort append-only event log for the phase transition.
    case Archive.get(:missions, mission_id) do
      nil ->
        {:error, :not_found}

      mission ->
        from_phase = Map.get(mission, :current_phase, "pending")

        if !recent_duplicate_transition?(mission_id, from_phase, "completed") do
          Archive.insert(:mission_phase_transitions, %{
            mission_id: mission_id,
            from_phase: from_phase,
            to_phase: "completed",
            reason: reason,
            seq: System.monotonic_time(:microsecond)
          })

          GiTF.EventStore.record(:phase_transition, mission_id, %{
            from: from_phase,
            to: "completed",
            reason: reason,
            outcome: "failed"
          })
        end

        result =
          Archive.update(:missions, mission_id, fn m ->
            m
            |> Map.put(:current_phase, "completed")
            |> Map.put(:status, "failed")
            |> Map.put(:failure_reason, reason)
          end)

        notify_aramaki_terminal(mission, {:failed, reason})
        result
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
          # Non-destructive: never reset --hard / clean -fd a shared repo that
          # may hold human WIP. Aborts an in-progress merge or stashes changes.
          GiTF.Git.safe_rollback(path, sid)
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

      Archive.update(:missions, mission_id, fn m ->
        %{m | status: "closed"} |> Map.delete(:ops)
      end)
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
    Archive.update(:missions, mission_id, fn
      %{status: "pending"} = m -> {:ok, %{m | status: "planning"}}
      _other -> {:error, :invalid_transition}
    end)
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
  # "scoring" is intentionally NOT in this list: by the time the mission is
  # in the scoring phase, publish has already run and the user-visible status
  # is "completed" (set by `mark_user_visible_completed/1`). Suppressing the
  # computed "completed" there would regress an already-finalized state.
  @pipeline_phases ["implementation", "validation", "awaiting_approval", "sync", "simplify", "publish"]

  @spec update_status!(String.t()) :: {:ok, map()} | {:error, term()}
  def update_status!(mission_id) do
    # Atomic read-modify-write on the mission record. Read ops INSIDE the
    # closure so the ops snapshot we compute status from is the same one
    # we write against — closing the read-then-lock race.
    result =
      Archive.update(:missions, mission_id, fn mission ->
        # Terminal-state guard: never overwrite "failed" or "completed" here.
        # `fail_quest` and `complete_quest` are the only paths allowed to set
        # those, and a recomputed status must not regress them.
        cond do
          mission.status == "failed" ->
            {:ok, mission, %{transitioned: false, old_status: "failed"}}

          mission.status == "completed" ->
            {:ok, mission, %{transitioned: false, old_status: "completed"}}

          true ->
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

            if mission.status == "planning" and op_statuses == [] do
              {:ok, mission, %{transitioned: false, old_status: mission.status}}
            else
              new_status = compute_status(op_statuses)

              new_status =
                if new_status == "completed" and Map.get(mission, :current_phase) in @pipeline_phases do
                  Logger.debug(
                    "Mission #{mission_id}: suppressing premature 'completed' — still in #{mission.current_phase} phase"
                  )

                  "active"
                else
                  new_status
                end

              transitioned = new_status != mission.status

              {:ok, %{mission | status: new_status},
               %{transitioned: transitioned, old_status: mission.status}}
            end
        end
      end)

    # Emit telemetry outside the lock, but only on an actual transition.
    case result do
      {:ok, %{status: "completed"} = mission, %{transitioned: true}} ->
        GiTF.Telemetry.emit([:gitf, :mission, :completed], %{}, %{
          mission_id: mission.id,
          name: mission[:name]
        })

      _ ->
        :ok
    end

    case result do
      {:ok, mission, _meta} -> {:ok, mission}
      other -> other
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
    e ->
      require Logger
      Logger.warning("compact_old_artifacts failed: #{Exception.message(e)}")
      0
  end

  @keep_artifacts ~w(requirements scoring)

  @doc """
  Replaces bulky artifacts with compact stubs for a single mission.
  Keeps requirements and scoring intact.
  """
  @spec compact_artifacts(String.t()) :: :ok
  def compact_artifacts(mission_id) do
    Archive.update(:missions, mission_id, fn mission ->
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

      Map.put(mission, :artifacts, compacted)
    end)

    :ok
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
    Archive.update(:missions, mission_id, fn mission ->
      phase_jobs = Map.get(mission, :phase_jobs, %{})
      Map.put(mission, :phase_jobs, Map.put(phase_jobs, phase, op_id))
    end)
  end

  @doc """
  Whether an operator has cleared the `await_operator` gate on `phase_id`
  for this mission. Takes the mission map (as held by the Advancer).
  """
  @spec gate_cleared?(map(), String.t()) :: boolean()
  def gate_cleared?(mission, phase_id) when is_map(mission) do
    phase_id in Map.get(mission, :cleared_gates, [])
  end

  @doc """
  Records operator clearance of the `await_operator` gate on `phase_id`,
  letting the pipeline advance past that phase. Idempotent.

  Returns `{:ok, mission}` or `{:error, :not_found}`.
  """
  @spec clear_gate(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def clear_gate(mission_id, phase_id) do
    Archive.update(:missions, mission_id, fn mission ->
      cleared = Map.get(mission, :cleared_gates, [])
      Map.put(mission, :cleared_gates, Enum.uniq([phase_id | cleared]))
    end)
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
    # Record the transition log entry + event FIRST (it's an append-only event
    # keyed on the caller's view of current_phase). The authoritative update
    # of current_phase/status is then done atomically via Archive.update so
    # concurrent callers don't clobber each other.
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

          GiTF.EventStore.record(:phase_transition, mission_id, %{
            from: from_phase,
            to: to_phase,
            reason: reason
          })
        end

        Archive.update(:missions, mission_id, fn m ->
          # Read status/phase fresh inside the lock
          status =
            case to_phase do
              "completed" -> m.status
              "pending" -> "pending"
              _ -> "active"
            end

          # Respect terminal "failed" status — never regress it here.
          status = if m.status == "failed", do: "failed", else: status

          m
          |> Map.put(:current_phase, to_phase)
          |> Map.put(:status, status)
        end)
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
    e ->
      require Logger

      Logger.warning(
        "recent_duplicate_transition? failed for mission #{mission_id}: #{Exception.message(e)}",
        mission_id: mission_id
      )

      false
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
