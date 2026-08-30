defmodule GiTF.Missions do
  @moduledoc """
  Context module for mission lifecycle management.

  A mission is a high-level objective decomposed into ops. Its status is
  derived from the collective state of its ops via `compute_status/1`,
  a pure function that maps op statuses to a mission status.

  This is a pure context module: no process state, just data transformations
  against the store.

  ## Resume provenance

  `resume/2` starts a new mission on a failed one's tree, replaying the
  phases before the resume point from the parent's artifacts instead of
  re-running them. That saves hours, and it costs certainty.

  **Inherited state is a suspect in every failure of a resumed run.** The
  design the parent produced, the plan cut from it, and the tree left in
  `archive/<parent_id>` were all authored by a run that DID NOT SUCCEED.
  Any of them can be the reason the child fails too, and nothing downstream
  can tell an inherited defect from a fresh one — the child's own ghosts
  never saw the requirements that produced the code they are judged on.

  So: if a resumed run fails in a way that might implicate inherited state
  — a design gap, a plan that never covered the requirement, a tree with
  work missing — the answer is a fresh full run, not another resume. Resume
  is for re-entering a loop that was working (validation ↔ fix) when the
  factory, not the work, gave out. Stacking resumes on resumes compounds
  provenance until no post-mortem can say where the defect entered.

  One thing a resumed run may NOT inherit is a clean slate on the
  verdicts that killed its parent. `inherited_contested/1` carries every
  requirement the lineage judged unmet into the child's
  `contested_requirements`, and the accepted set is reduced by it — msn-978954
  passed a requirement its parent had rejected, on identical code, because
  the child's validator was never told the argument had already been had.
  """

  require Logger
  require GiTF.Ghost.Status, as: GhostStatus

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

  # Phases (not statuses) that mean the pipeline is over. The dashboard, the
  # MCP handlers and the ledger each grew their own copy of this list with
  # different membership; this is the one that counts.
  @terminal_phases ~w(completed failed closed killed)

  @doc "Phases that end a mission's pipeline."
  @spec terminal_phases() :: [String.t()]
  def terminal_phases, do: @terminal_phases

  # The phases whose meaning is "the factory has stopped and a PERSON is
  # the blocker". Four separate mechanisms have to know this list, and
  # every one of them is wrong in a way that costs something real if it
  # drifts:
  #
  #   * Tachikoma's stall detector — a held mission has no live ghost BY
  #     DESIGN, which is the exact shape it calls a stall. Without the
  #     exclusion every human gate pages the operator as an orchestration
  #     failure ten minutes in.
  #   * The mission age cap — force-completing a mission because a human
  #     was asleep is the cap punishing the wrong party.
  #   * The budget cap — a held mission spends nothing while it waits.
  #   * The vault kanban — both gates belong in Review, not Doing.
  #
  # One list, so adding a third gate cannot silently miss one of them.
  @human_gate_phases ~w(awaiting_approval awaiting_input)

  @doc "Phases where the mission is stopped and a human is the blocker."
  @spec human_gate_phases() :: [String.t()]
  def human_gate_phases, do: @human_gate_phases

  @doc "True when the mission is stopped waiting on a person."
  @spec held_for_human?(map()) :: boolean()
  def held_for_human?(mission) when is_map(mission),
    do: Map.get(mission, :current_phase) in @human_gate_phases

  def held_for_human?(_), do: false

  @doc """
  When the mission actually ENDED: the timestamp of its transition into a
  terminal phase, from a pre-sorted transition list or a mission id. Nil when
  no terminal transition exists. `updated_at` is not this — it moves whenever
  anything writes to a finished mission (outcome polls, boot sweeps), which
  is how a 28-minute run once read as "4h 44m".
  """
  @spec terminal_transition_at([map()] | String.t()) :: DateTime.t() | nil
  def terminal_transition_at(mission_id) when is_binary(mission_id),
    do: mission_id |> get_phase_transitions() |> terminal_transition_at()

  def terminal_transition_at(transitions) when is_list(transitions) do
    transitions
    |> Enum.reverse()
    |> Enum.find_value(fn t ->
      if t[:to_phase] in @terminal_phases, do: t[:inserted_at]
    end)
  end

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

  # -- Resume ------------------------------------------------------------------

  # v1 scope. `"validation"` is the endgame-iteration loop: everything before
  # implementation is inherited, the parent's final tree is checked out, and
  # the mission re-enters at consolidation → validation → fix. Earlier resume
  # points would have to re-derive a tree from artifacts, which is a different
  # (and much less certain) operation.
  @resumable_phases ["validation"]

  # Phases whose artifacts are inherited when resuming AT the key. Ordered:
  # the replayed transitions are written in this order so the timeline reads
  # as the journey it stands in for.
  @inherited_phases %{
    "validation" => ~w(triage research requirements design review planning)
  }

  @doc "Phases `resume/2` can restart a mission at."
  @spec resumable_phases() :: [String.t()]
  def resumable_phases, do: @resumable_phases

  @doc """
  Starts a NEW mission on a failed mission's preserved tree, re-entering
  the pipeline at `from_phase` instead of running it from the top.

  Only `"validation"` is supported (the endgame-iteration loop). The
  parent's canonical branch must already be archived as
  `archive/<parent_id>` — `fail_quest/2` and `kill/1` do that automatically
  since the branch-preservation change; missions that failed before it have
  nothing to resume from.

  What the child inherits:

    * the parent's goal, sector and `pipeline_mode` (including the forced
      flag — an operator's choice of mode outlives the run that carried it),
    * the phase artifacts for every phase before `from_phase`, each stamped
      `"inherited_from" => parent_id` inside the artifact map,
    * a replayed phase transition per inherited phase, reasoned
      `"inherited from <parent_id>"` so the timeline distinguishes a
      replayed leg from a real one,
    * one synthetic `"done"` implementation op holding a worktree cut from
      `archive/<parent_id>` — which is what makes
      `GiTF.Validation.canonical_impl_shell/1` resolve to the parent's final
      tree, and what lets the journey advance into validation on its own.

  Resume implies start: the mission is left `status: "active"`,
  `current_phase: "implementation"`, and handed to
  `GiTF.Major.Orchestrator.advance_quest/1`. There is no separate
  `start_mission` step.

  Read the module doc's provenance rule before acting on a resumed run's
  failure.

  ## Options

    * `:advance` (default `true`) — hand the finished mission to the
      orchestrator. The only reason to pass `false` is to build the child
      and inspect it without spawning a validation ghost; production always
      advances, because a resumed mission nobody advances is a checked-out
      worktree holding the parent's only tree and doing nothing.
    * `:async` (default `false`) — return as soon as the record and its
      provenance exist, seeding the worktree in a supervised task. See
      `resume_with_status/3`.

  ## One live resume per parent

  A parent has exactly one resumable tree, so it gets at most one live
  child: if a non-terminal mission already carries
  `resumed_from == parent_id`, that mission is returned instead of a
  second one being built. Two timed-out MCP calls produced FOUR duplicate
  missions racing for the same archive branch before this guard existed.

  Returns `{:ok, mission}` or one of `{:error, :parent_not_found |
  :parent_not_failed | :unsupported_from_phase | :sector_unavailable |
  :archive_branch_missing | term()}`.
  """
  @spec resume(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def resume(parent_id, from_phase \\ "validation", opts \\ [])

  def resume(parent_id, from_phase, opts) do
    case resume_with_status(parent_id, from_phase, opts) do
      {:ok, mission, _status} -> {:ok, mission}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  `resume/3`, plus whether the returned mission was built by THIS call.

  `:created` means a new child; `:already_resumed` means the parent's
  existing live child was returned untouched. The MCP handler needs the
  difference — an operator who calls `resume_mission` twice must be told
  the second call did nothing, not shown a mission id and left to assume
  a second run started.

  With `async: true` the seeding half (`GiTF.Shell.create` cutting a
  worktree from the archive branch, then `advance_quest`) runs in a
  supervised task and this returns as soon as the record, its inherited
  artifacts and its replayed transitions exist. The child is left
  `status: "pending"` until seeding completes precisely so no scheduler
  can advance a mission whose tree does not exist yet; failure fails the
  mission with a reason rather than leaving a pending zombie. Watch it
  with `show_mission`.
  """
  @spec resume_with_status(String.t(), String.t(), keyword()) ::
          {:ok, map(), :created | :already_resumed} | {:error, term()}
  def resume_with_status(parent_id, from_phase \\ "validation", opts \\ [])

  def resume_with_status(parent_id, from_phase, opts)
      when is_binary(parent_id) and is_binary(from_phase) do
    # Serialized on the PARENT: the duplicate storm was two concurrent
    # calls, so a check that is not inside the lock is not a guard.
    GiTF.MissionLock.with_lock({:resume, parent_id}, [on_contention: {:wait, 30_000}], fn ->
      with :ok <- validate_from_phase(from_phase),
           {:ok, parent} <- fetch_resumable_parent(parent_id),
           {:ok, archive_branch} <- fetch_archive_branch(parent) do
        case live_resume_of(parent_id) do
          nil -> build_resumed_mission(parent, from_phase, archive_branch, opts)
          existing -> {:ok, existing, :already_resumed}
        end
      end
    end)
  end

  def resume_with_status(_parent_id, _from_phase, _opts), do: {:error, :parent_not_found}

  @doc """
  The parent's live resumed child, or nil.

  "Live" is anything not in `terminal_phases/0` — a failed or completed
  resume is spent and the parent may be resumed again.
  """
  @spec live_resume_of(String.t()) :: map() | nil
  def live_resume_of(parent_id) do
    Archive.filter(:missions, fn m ->
      m[:resumed_from] == parent_id and m[:status] not in @terminal_phases
    end)
    |> Enum.sort_by(& &1[:inserted_at], {:asc, DateTime})
    |> List.first()
  end

  defp validate_from_phase(phase) do
    if phase in @resumable_phases, do: :ok, else: {:error, :unsupported_from_phase}
  end

  defp fetch_resumable_parent(parent_id) do
    case Archive.get(:missions, parent_id) do
      nil ->
        {:error, :parent_not_found}

      # `kill/1` deletes the record, so "killed" is only reachable for
      # missions some other path marked killed without deleting. Accepted
      # anyway: the check is about "nobody is still working on this", and a
      # live mission must never have its tree resumed underneath it.
      %{status: status} = parent when status in ["failed", "killed"] ->
        {:ok, Map.put(parent, :ops, GiTF.Ops.list(mission_id: parent_id))}

      _ ->
        {:error, :parent_not_failed}
    end
  end

  defp fetch_archive_branch(parent) do
    branch = GiTF.Major.Topology.archive_branch(parent.id)

    with sector_id when is_binary(sector_id) <- Map.get(parent, :sector_id),
         %{path: path} when is_binary(path) <- Archive.get(:sectors, sector_id),
         true <- File.dir?(path) do
      if GiTF.Git.branch_exists?(path, branch) do
        {:ok, branch}
      else
        {:error, :archive_branch_missing}
      end
    else
      _ -> {:error, :sector_unavailable}
    end
  end

  defp build_resumed_mission(parent, from_phase, archive_branch, opts) do
    async? = Keyword.get(opts, :async, false)

    with {:ok, child} <- create_resumed_record(parent, from_phase, async?),
         :ok <- inherit_artifacts(child, parent, from_phase),
         :ok <- replay_transitions(child, parent, from_phase) do
      if async? do
        seed_async(child, parent, archive_branch, from_phase, opts)
        with {:ok, mission} <- get(child.id), do: {:ok, mission, :created}
      else
        with :ok <- seed_and_launch(child, parent, archive_branch, from_phase, opts),
             {:ok, mission} <- get(child.id),
             do: {:ok, mission, :created}
      end
    end
  end

  # The slow half — minutes under load, because `GiTF.Shell.create` cuts a
  # real worktree from the archive branch and `advance_quest` may spawn a
  # ghost. The same code either way; only the process it runs in differs.
  defp seed_and_launch(child, parent, archive_branch, from_phase, opts) do
    with {:ok, _op} <- seed_inherited_tree(child, parent, archive_branch) do
      # Only NOW may a scheduler see it. The synthetic op is already
      # "done", so `check_implementation_complete` walks straight into
      # start_validation — and it must not do that against a tree that
      # does not exist yet.
      update(child.id, %{status: "active", resume_seeding: false})
      transition_phase(child.id, "implementation", "resumed from #{parent.id} at #{from_phase}")

      if Keyword.get(opts, :advance, true) do
        GiTF.Major.Orchestrator.advance_quest(child.id)
      end

      :ok
    end
  end

  # Seeding synchronously took >60s under load: the MCP client timed out,
  # the operator retried, and the server carried on regardless — four
  # missions out of two calls. The caller now gets its id back immediately
  # and watches `show_mission`. The one rule this task must honour is that
  # it never leaves a mission parked at "pending" forever.
  defp seed_async(child, parent, archive_branch, from_phase, opts) do
    Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
      case guarded_seed(child, parent, archive_branch, from_phase, opts) do
        :ok -> :ok
        {:error, reason} -> abandon_resume(child.id, reason)
      end
    end)
  end

  defp guarded_seed(child, parent, archive_branch, from_phase, opts) do
    seed_and_launch(child, parent, archive_branch, from_phase, opts)
  rescue
    e -> {:error, {:crashed, Exception.message(e)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp abandon_resume(child_id, reason) do
    Logger.error("Quest #{child_id}: resume seeding failed: #{inspect(reason)}")
    Archive.update(:missions, child_id, &Map.put(&1, :resume_seeding, false))

    fail_quest(
      child_id,
      "Resume could not provision the inherited worktree (#{inspect(reason)}) — " <>
        "no tree was seeded, so nothing ran"
    )

    :ok
  end

  defp create_resumed_record(parent, from_phase, async?) do
    contested = inherited_contested(parent)
    contested_ids = Enum.map(contested, & &1["req_id"])

    with {:ok, child} <-
           create(%{
             goal: parent.goal,
             sector_id: parent[:sector_id],
             name: "#{parent[:name] || parent.id}-resume",
             # An async resume parks at "pending" until its worktree
             # exists; "active" would invite the scheduler to advance a
             # mission that has no tree.
             status: if(async?, do: "pending", else: "active")
           }) do
      update(child.id, %{
        resumed_from: parent.id,
        resumed_at_phase: from_phase,
        # Visible in `show_mission` so an operator watching an async resume
        # can tell "worktree still being cut" from "nothing is happening".
        resume_seeding: async?,
        # An operator's forced pipeline mode is a decision about the WORK,
        # not about the run that carried it — it survives the resume.
        pipeline_mode: parent[:pipeline_mode],
        pipeline_mode_forced: parent[:pipeline_mode_forced] || false,
        target_branch: parent[:target_branch],
        cost_cap_usd: parent[:cost_cap_usd],
        # The two requirement registers cross the resume boundary
        # together, or the child's validator gets to un-know what its
        # parent found. Accepted loses anything still contested: an id on
        # both lists is a contradiction, and the fail-closed reading is
        # the only safe one.
        contested_requirements: contested,
        accepted_requirements: inherited_accepted(parent, contested_ids),
        # A question the operator has already answered is a decision, not
        # state the child gets to re-derive. Re-asking it spends their
        # attention a second time on a matter that was settled, and the
        # second answer can differ from the first — which would make the
        # resumed run's provenance unreadable in exactly the way the
        # requirement registers exist to prevent.
        answered_inquiries: inherited_answers(parent)
      })
    end
  end

  # Ten is a bound, not a belief: `resume/3` already refuses to stack a
  # resume on a live one, and the module doc argues against stacking them
  # at all. The cap exists so a cycle written by hand into the records
  # cannot walk forever.
  @resume_lineage_hops 10

  @doc """
  The requirements some validator in `parent`'s resume lineage judged
  UNMET and nobody has since argued out of that state, as
  `%{"req_id" => id, "reason" => text}`.

  A `met: true` ANYWHERE in the history does not clear contestation — a
  bare flip is exactly the false pass this contract closes (msn-978954:
  the child's validator re-judged its parent's rejected FR-5 as met, on
  identical code, while re-filing the same concern as "minor"). Only a
  flip carrying a real rebuttal clears it, and that rule holds across the
  lineage as well as within a run.

  The cost of that strictness is deliberate and small: a requirement an
  ancestor genuinely fixed arrives contested in the child, and the
  child's validator spends one honest sentence citing the fix. The cost
  of the alternative is a shipped gap nobody can see in the artifact.
  """
  @spec inherited_contested(map()) :: [map()]
  def inherited_contested(parent) do
    from_artifacts =
      parent |> resume_lineage() |> Enum.flat_map(&lineage_requirement_entries/1)

    entries = from_artifacts ++ contested_field_entries(parent)

    rebutted =
      for {:rebutted, id} <- entries, into: MapSet.new(), do: id

    unmet =
      for {:unmet, id, reason} <- entries,
          not MapSet.member?(rebutted, id),
          do: {id, reason}

    # Map.new keeps the LAST value for a duplicate key, and the lineage is
    # ordered oldest-first, so the freshest articulation of what is wrong
    # is the one the next round gets quoted.
    reasons = Map.new(unmet)

    unmet
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.map(&%{"req_id" => &1, "reason" => reasons[&1]})
  end

  defp inherited_accepted(parent, contested_ids) do
    (parent[:accepted_requirements] || []) -- contested_ids
  end

  @doc """
  Every question the operator answered anywhere in `parent`'s resume
  lineage, as the register `GiTF.Inquiry.ask/2` consults before it opens
  anything: `%{"phase" => _, "key" => _, "answer" => _, ...}`.

  Keyed on `{phase, key}`, never on prompt text — a ghost that rewords
  its own question between runs is asking the same question, and the
  operator should not have to notice that.

  Later entries win, and the lineage walks oldest-first, so a decision
  made further down the chain outranks the one it superseded. Both the
  parent's own answered inquiries and the register it inherited are
  included: a lineage three resumes deep must not quietly forget the
  answer given at the top of it.
  """
  @spec inherited_answers(map()) :: [map()]
  def inherited_answers(parent) do
    parent
    |> resume_lineage()
    |> Enum.flat_map(&lineage_answer_entries/1)
    |> Enum.reduce(%{}, fn entry, acc ->
      Map.put(acc, {entry["phase"], entry["key"]}, entry)
    end)
    |> Map.values()
    |> Enum.sort_by(&{&1["phase"], &1["key"]})
  rescue
    # An unreadable register must cost the child its inheritance, not its
    # existence. Worst case the operator is asked one question twice.
    _ -> []
  end

  defp lineage_answer_entries(record) do
    inherited =
      for entry <- record[:answered_inquiries] || [],
          is_map(entry),
          is_binary(entry["phase"]),
          is_binary(entry["key"]),
          do: entry

    inherited ++ GiTF.Inquiry.answered_register(record[:id])
  end

  # Oldest ancestor first, `parent` last. A missing ancestor record (the
  # mission was killed and reaped) truncates the walk rather than failing
  # it — a partial lineage still contests more than no lineage.
  defp resume_lineage(parent), do: walk_resume_lineage(parent, @resume_lineage_hops, [])

  defp walk_resume_lineage(nil, _hops, acc), do: acc
  defp walk_resume_lineage(record, 0, acc), do: [record | acc]

  defp walk_resume_lineage(record, hops, acc) do
    case record[:resumed_from] do
      id when is_binary(id) ->
        walk_resume_lineage(Archive.get(:missions, id), hops - 1, [record | acc])

      _ ->
        [record | acc]
    end
  end

  # Same key rule as `Phases.Validation.validation_artifacts/1`, restated
  # against a raw Archive record (that one reads a loaded mission map).
  # Sorted so a tournament's variants contribute in a stable order.
  defp lineage_requirement_entries(record) do
    mission_id = record[:id]

    (Map.get(record, :artifacts) || %{})
    |> Enum.filter(fn {key, value} ->
      is_binary(key) and String.starts_with?(key, "validation") and is_map(value)
    end)
    |> Enum.sort_by(fn {key, _artifact} -> key end)
    |> Enum.flat_map(fn {_key, artifact} -> requirement_entries(artifact, mission_id) end)
  end

  defp requirement_entries(%{"requirements_met" => entries}, mission_id) when is_list(entries) do
    for entry <- entries,
        is_map(entry),
        id = entry["req_id"] || entry["id"],
        is_binary(id) and id != "",
        classified = classify_requirement_entry(entry, id, mission_id),
        classified != nil,
        do: classified
  end

  defp requirement_entries(_artifact, _mission_id), do: []

  defp classify_requirement_entry(entry, id, mission_id) do
    cond do
      entry["met"] == false -> {:unmet, id, lineage_unmet_reason(entry, mission_id)}
      entry["met"] == true and lineage_rebutted?(entry) -> {:rebutted, id}
      true -> nil
    end
  end

  defp lineage_rebutted?(entry) do
    case entry["rebuttal"] do
      text when is_binary(text) ->
        String.length(String.trim(text)) >= GiTF.Phases.Validation.rebuttal_min_chars()

      _ ->
        false
    end
  end

  defp lineage_unmet_reason(entry, mission_id) do
    case entry["evidence"] do
      text when is_binary(text) ->
        case String.trim(text) do
          "" -> "previously judged unmet in #{mission_id}"
          trimmed -> trimmed
        end

      _ ->
        "previously judged unmet in #{mission_id}"
    end
  end

  # The parent's own register, applied last so a standing verdict the
  # parent recorded outranks the artifact it was derived from.
  defp contested_field_entries(parent) do
    for entry <- parent[:contested_requirements] || [],
        is_map(entry),
        id = entry["req_id"],
        is_binary(id) and id != "",
        do: {:unmet, id, contested_field_reason(entry)}
  end

  defp contested_field_reason(entry) do
    case entry["reason"] do
      text when is_binary(text) and text != "" -> text
      _ -> "previously judged unmet"
    end
  end

  # Every artifact is stamped INSIDE the map rather than tracked in a
  # sidecar: a phase artifact travels alone into prompts, diagnosis output
  # and the dashboard, and an unstamped copy is indistinguishable from work
  # this run actually did.
  defp inherit_artifacts(child, parent, from_phase) do
    phases = Map.get(@inherited_phases, from_phase, [])
    parent_artifacts = Map.get(parent, :artifacts, %{}) || %{}

    inherited =
      parent_artifacts
      |> Enum.filter(fn {key, value} -> inheritable?(key, phases) and is_map(value) end)
      |> Map.new(fn {key, value} -> {key, Map.put(value, "inherited_from", parent.id)} end)

    Archive.update(:missions, child.id, fn m ->
      Map.put(m, :artifacts, Map.merge(Map.get(m, :artifacts, %{}) || %{}, inherited))
    end)

    :ok
  end

  # Parallel phases write suffixed keys ("design_minimal", "planning_thorough",
  # "validation_v2"). Prefix-matching carries the whole family, so a resumed
  # design tournament arrives with its full field rather than one variant.
  defp inheritable?(key, phases) when is_binary(key) do
    Enum.any?(phases, fn phase -> key == phase or String.starts_with?(key, phase <> "_") end)
  end

  defp inheritable?(_key, _phases), do: false

  defp replay_transitions(child, parent, from_phase) do
    inherited_artifacts = Map.get(parent, :artifacts, %{}) || %{}

    Map.get(@inherited_phases, from_phase, [])
    |> Enum.filter(fn phase ->
      Enum.any?(Map.keys(inherited_artifacts), &inheritable?(&1, [phase]))
    end)
    |> Enum.each(fn phase ->
      transition_phase(child.id, phase, "inherited from #{parent.id}")
    end)

    :ok
  end

  # THE SEED. `canonical_impl_shell/1` resolves op → ghost → shell →
  # worktree; a resumed mission has no real ghost that ever ran, so all
  # three records are minted by hand around a worktree cut from the archive
  # branch. Get any link wrong and consolidation, validation, the fix loop
  # and publish all silently target the sector base instead of the
  # inherited tree.
  defp seed_inherited_tree(child, parent, archive_branch) do
    with {:ok, op} <- create_inherited_op(child, parent),
         {:ok, ghost} <- Archive.insert(:ghosts, inherited_ghost_record(op.id)),
         {:ok, shell} <- create_inherited_shell(child, ghost, archive_branch) do
      Archive.update(:ghosts, ghost.id, fn g ->
        Map.merge(g, %{shell_id: shell.id, shell_path: shell.worktree_path})
      end)

      Archive.update(:ops, op.id, fn o ->
        Map.merge(o, %{ghost_id: ghost.id, shell_id: shell.id, branch: shell.branch})
      end)

      Logger.info(
        "Quest #{child.id}: seeded inherited tree from #{archive_branch} " <>
          "(op #{op.id}, ghost #{ghost.id}, worktree #{shell.worktree_path})"
      )

      scrub_seeded_residue(child, shell.worktree_path)

      {:ok, op}
    else
      {:error, reason} ->
        # A resumed mission whose tree could not be provisioned would run
        # validation against the sector base and report the inherited work
        # missing. Fail loudly at creation instead.
        Logger.error("Quest #{child.id}: could not seed inherited tree: #{inspect(reason)}")
        fail_quest(child.id, "Resume could not provision the inherited worktree")
        {:error, {:seed_failed, reason}}
    end
  end

  # The seeded tree is the ONLY moment the factory can undo a commit an
  # earlier run made before the residue guards existed: from here on
  # every sink protects the index but nothing removes what is already
  # tracked, so the inherited `.gitf-probe/*.png` would ride out through
  # the resumed run's PR. Strictly best-effort — a scrub that fails
  # leaves the run cosmetically dirty, and failing the seed over it would
  # trade a cosmetic defect for a dead mission.
  defp scrub_seeded_residue(child, worktree_path) do
    case GiTF.Git.scrub_committed_residue(worktree_path) do
      {:ok, paths} ->
        Logger.info(
          "Quest #{child.id}: scrubbed committed probe residue from the inherited tree " <>
            "(#{Enum.join(paths, ", ")})"
        )

      {:error, reason} ->
        Logger.warning(
          "Quest #{child.id}: could not scrub committed probe residue " <>
            "(#{inspect(reason)}) — continuing; the residue rides along"
        )

      :noop ->
        :ok
    end
  end

  defp create_inherited_op(child, parent) do
    # The parent's changed files ride along: `validate_pass_against_diff/1`
    # overrides a "pass" verdict when no completed impl op reports a
    # meaningful file, and the synthetic op is the ONLY impl op a resumed
    # mission has. Leaving this empty makes the resumed run unpassable.
    changed = parent_changed_files(parent)

    with {:ok, op} <-
           GiTF.Ops.create(%{
             title: "Inherited implementation from #{parent.id}",
             description:
               "Placeholder for the implementation work inherited from mission #{parent.id}. " <>
                 "No ghost ran for this op; its worktree is checked out at that mission's " <>
                 "final tree (#{GiTF.Major.Topology.archive_branch(parent.id)}).",
             mission_id: child.id,
             sector_id: child[:sector_id],
             status: "done",
             phase_job: false,
             skip_verification: true
           }) do
      # `Ops.create/1` builds a fixed record and drops unknown keys, so the
      # resume-specific fields are merged after the insert rather than
      # passed in (silently losing `inherited` would make the synthetic op
      # indistinguishable from real work in every post-mortem).
      Archive.update(:ops, op.id, fn o ->
        Map.merge(o, %{
          inherited: true,
          changed_files: changed,
          files_changed: length(changed)
        })
      end)
    end
  end

  defp parent_changed_files(parent) do
    (parent[:ops] || [])
    |> Enum.reject(& &1[:phase_job])
    |> Enum.flat_map(fn op -> op[:changed_files] || [] end)
    |> Enum.uniq()
  end

  defp inherited_ghost_record(op_id) do
    %{
      name: "inherited",
      status: GhostStatus.stopped(),
      op_id: op_id,
      shell_path: nil,
      shell_id: nil,
      pid: nil,
      assigned_model: nil,
      context_tokens_used: 0,
      context_tokens_limit: nil,
      context_percentage: 0.0,
      inherited: true
    }
  end

  defp create_inherited_shell(child, ghost, archive_branch) do
    opts = [base_branch: archive_branch]

    opts =
      case GiTF.gitf_dir() do
        {:ok, root} -> Keyword.put(opts, :gitf_root, root)
        _ -> opts
      end

    GiTF.Shell.create(child[:sector_id], ghost.id, opts)
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
  @doc """
  Fires the terminal notification for a mission that reached a terminal
  status without one, and normalises its phase.

  Terminal transitions are supposed to run through `complete_quest` or
  `fail_quest`, which notify. Not every path does: a mission was left
  `status: "failed"` with `current_phase: "validation"` and no
  `failure_reason`, so the reviewer who asked for the change was never told
  what happened — and the Janitor re-advanced it every 3 minutes forever
  because its phase never became terminal.

  Idempotent via the existing `aramaki_notified` flag, so a repaired record
  cannot double-post.
  """
  @spec ensure_terminal_notified(map()) :: :ok
  def ensure_terminal_notified(mission) do
    if finished?(mission) and not Map.get(mission, :aramaki_notified, false) do
      outcome =
        case Map.get(mission, :status) do
          "completed" -> :completed
          _ -> {:failed, Map.get(mission, :failure_reason) || "ended without a recorded reason"}
        end

      notify_aramaki_terminal(mission, outcome)

      if Map.get(mission, :current_phase) not in ["completed", "terminal"] do
        Archive.update(:missions, mission.id, &Map.put(&1, :current_phase, "completed"))
      end
    end

    :ok
  end

  defp notify_aramaki_terminal(mission, outcome) do
    source = Map.get(mission, :source)

    if source in ["github_issue", "project", "pr_review"] and
         !Map.get(mission, :aramaki_notified, false) do
      Archive.update(:missions, mission.id, &Map.put(&1, :aramaki_notified, true))

      case source do
        "github_issue" ->
          case outcome do
            :completed -> GiTF.Aramaki.Lifecycle.on_merged(mission)
            {:failed, reason} -> GiTF.Aramaki.Lifecycle.on_failed(mission, reason || "unknown")
          end

        # A review asked for changes; the reviewer is owed an answer either
        # way. Silence after a request is indistinguishable from the factory
        # never having seen it.
        "pr_review" ->
          case outcome do
            :completed ->
              GiTF.Aramaki.Lifecycle.on_review_addressed(mission)

            {:failed, reason} ->
              GiTF.Aramaki.Lifecycle.on_review_failed(mission, reason || "unknown")
              # The request was not satisfied, so it is not handled. Release it
              # (up to a retry limit) rather than consuming the reviewer's
              # feedback on a run that never landed.
              GiTF.GitHub.ReviewIntake.release(mission)
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
        # FIRST, before the status write: once this mission reads "failed",
        # the orphan sweep and the shell reaper are free to remove its
        # worktrees and delete its ghost branches. Preserve the tree while
        # it still exists — this is the only input `resume/2` has.
        preserve_canonical_branch(mission_id)

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
        # Before the ops (and with them the shells and worktrees) go away.
        # A killed mission's work is as resumable as a failed one's, and
        # `kill` is the more destructive of the two — it deletes the record.
        preserve_canonical_branch(mission_id)

        # Rollback sector if applicable
        rollback_sector(quest)

        GiTF.Ops.list(mission_id: mission_id)
        |> Enum.each(fn op -> GiTF.Ops.kill(op[:id] || op.id) end)

        # Tell whoever asked for this work that it stopped, BEFORE the record
        # goes away. Killing deletes the mission outright, so nothing
        # downstream can sweep it: a killed review-driven run left the
        # reviewer with no reply and their request marked handled forever,
        # recoverable only by editing the store by hand. Idempotent via
        # aramaki_notified, and a no-op for missions with no external source.
        notify_aramaki_terminal(quest, {:failed, "killed by operator"})

        Archive.delete(:missions, mission_id)
        :ok
    end
  end

  # Never let branch archival break a failure path: a mission that failed
  # must be recorded as failed even when its sector clone is missing, its
  # worktrees are already gone, or git is unhappy. Topology already logs
  # each error; this swallows whatever is left.
  defp preserve_canonical_branch(mission_id) do
    GiTF.Major.Topology.archive_canonical_branch(mission_id)
    :ok
  rescue
    e ->
      Logger.warning("Quest #{mission_id}: canonical branch preservation failed: #{inspect(e)}")

      :ok
  catch
    kind, reason ->
      Logger.warning(
        "Quest #{mission_id}: canonical branch preservation #{kind}: #{inspect(reason)}"
      )

      :ok
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
  @pipeline_phases [
    "implementation",
    "validation",
    "awaiting_input",
    "awaiting_approval",
    "sync",
    "simplify",
    "publish"
  ]

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
                if new_status == "completed" and
                     Map.get(mission, :current_phase) in @pipeline_phases do
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

  A `nil` reason is filled in from the phase actually being left. Callers
  used to pass a literal describing the phase that *usually* precedes this
  one — "Design complete" on the way into review — which reads as fact in
  the timeline and is wrong whenever triage skipped that phase. The
  from-phase read here is the authoritative one, so a derived reason cannot
  disagree with the transition it annotates the way a caller's stale copy
  of the mission can.
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
        reason = reason || "#{from_phase} complete"

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
