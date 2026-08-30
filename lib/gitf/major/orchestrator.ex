defmodule GiTF.Major.Orchestrator do
  @moduledoc """
  THE JOURNEY OF A MISSION — the state machine that walks a mission from
  `pending` to `completed`, one phase at a time.

  This module owns the SHAPE of the journey and nothing else. Each leg's
  actual work belongs to a named collaborator, and `advance_via_legacy/2`
  reads as the itinerary:

      triage → research → requirements → design → review → planning →
      implementation → validation → awaiting_approval → sync → simplify →
      publish → scoring

  One phase is missing from that line because it is not on it:
  `awaiting_input` is a *detour* any leg can take. A phase that hits a
  decision only the operator can make emits a question, the mission holds,
  and it returns to the same phase with the answer — sideways and back, not
  forward. `advance_mission_phase/1` settles it above the workflow fork; the
  reasoning lives in `GiTF.Inquiry.Gate`.

  The personas it calls out to:

  | Module | Its role in the journey |
  |---|---|
  | `GiTF.Major.Lifecycle` | The clock and the meter — age, budget, artifact honesty |
  | `GiTF.Major.PhaseLauncher` | Puts a ghost in the field for any phase |
  | `GiTF.Major.DesignBoard` | Runs the design tournament and its verdict |
  | `GiTF.Major.ModelPolicy` | Decides WHICH mind does a piece of work |
  | `GiTF.Major.Topology` | Worktree/branch terrain and consolidation |
  | `GiTF.Major.GroundTruth` | Does the tree actually build? |
  | `GiTF.Major.Endgame` | Post-consolidation conflict convergence |
  | `GiTF.Major.WorkflowBridge` | The same journey, driven by a workflow DSL |

  Each phase ghost produces a structured JSON artifact stored on the
  mission record. When a phase ghost's "job_complete" link_msg arrives,
  the Major calls `advance_quest/1`, which checks for the artifact and
  asks the launcher for the next leg.
  """

  require Logger

  alias GiTF.Archive

  alias GiTF.Major.{
    DesignBoard,
    FastPath,
    Lifecycle,
    ModelPolicy,
    PhaseLauncher,
    Planner,
    Topology,
    WorkflowBridge
  }

  alias GiTF.Major.Orchestrator.Decisions

  # Scoring is async post-processing that runs after publish. The mission is
  # user-visibly `status: "completed"` once publish lands; scoring + learning
  # (`ingest_mission_outcome`) continue in the background while
  # `post_processing_status` reflects their state. See `GiTF.Publish.start/1`.
  #
  # `awaiting_input` has no true position in this list and its neighbours are
  # a display choice, not a claim. ANY phase can raise a question, and the
  # mission returns to whichever one did (`input_return_phase`) — so the gate
  # is entered from everywhere and exited backwards. It sits next to
  # `awaiting_approval` because the two share a meaning the operator reads off
  # the strip at a glance: this region is where the factory stops for a
  # person. Progress is never computed from its index — the widgets resolve a
  # held mission's position from the phase it will return to, and
  # `GiTF.Inquiry.gate_state/1` decides how the step itself renders.
  @phases ~w(triage research requirements design review planning implementation validation awaiting_input awaiting_approval sync simplify publish scoring)

  # -- Public API --------------------------------------------------------------

  @doc """
  Start a mission workflow.

  Validates the mission is ready and kicks off the research phase.

  ## Options

    * `:force_fast_path` - skip the full pipeline and go straight to
      implementation with a single op (for bug fixes, focused tasks)
  """
  @spec start_quest(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_quest(mission_id, opts \\ []) do
    with {:ok, mission} <- GiTF.Missions.get(mission_id),
         :ok <- validate_quest_ready(mission),
         :ok <- budget_preflight(mission_id),
         :ok <- provider_preflight(),
         # `validate_quest_ready` may have auto-assigned a sector (writing
         # directly to Archive). Reload so the struct we hand to start_triage /
         # start_research has the updated sector_id.
         {:ok, mission} <- GiTF.Missions.get(mission_id) do
      GiTF.Telemetry.start_mission_span(mission_id, mission.goal)
      force = Keyword.get(opts, :force_fast_path, false)
      force_full = Keyword.get(opts, :force_full_pipeline, false)

      # Set pipeline mode: "fast" uses streamlined phases (1 design, skip review)
      pipeline_mode =
        if not force_full and FastPath.eligible?(mission, force: force) do
          Logger.info("Quest #{mission_id} eligible for fast path (streamlined pipeline)")
          "fast"
        else
          "full"
        end

      # An operator who named a mode outranks every later inference. Without
      # this the mode is indistinguishable from an inferred one, and triage
      # overwrites it — see Decisions.forced_pipeline_mode?/1.
      forced = force or force_full

      if forced do
        Logger.info("Quest #{mission_id} pipeline mode #{pipeline_mode} forced by operator")
      end

      GiTF.Missions.update(mission_id, %{
        pipeline_mode: pipeline_mode,
        pipeline_mode_forced: forced
      })

      planning_artifact = GiTF.Missions.get_artifact(mission_id, "planning")

      # Check for existing active ops (restart scenario — don't create duplicates)
      active_ops =
        Enum.filter(mission.ops, &(&1.status in ["pending", "running", "assigned", "blocked"]))

      existing_impl_ops = Enum.reject(active_ops, & &1[:phase_job])
      existing_phase_ops = Enum.filter(active_ops, & &1[:phase_job])

      cond do
        existing_phase_ops != [] ->
          Logger.info(
            "Quest #{mission_id} has #{length(existing_phase_ops)} active phase ops, triggering spawner"
          )

          GiTF.Missions.update(mission_id, %{status: "active"})
          send(Process.whereis(GiTF.Major), :spawn_ready_jobs)
          {:ok, mission[:current_phase] || "research"}

        existing_impl_ops != [] ->
          Logger.info(
            "Quest #{mission_id} has #{length(existing_impl_ops)} existing impl ops, triggering spawner"
          )

          GiTF.Missions.update(mission_id, %{status: "active"})
          send(Process.whereis(GiTF.Major), :spawn_ready_jobs)
          {:ok, "implementation"}

        planning_artifact && is_list(planning_artifact) && planning_artifact != [] ->
          Logger.info("Quest #{mission_id} has pre-confirmed plan, skipping to implementation")
          PhaseLauncher.start_implementation(mission)

        true ->
          if triage_enabled?() do
            PhaseLauncher.start_triage(mission)
          else
            PhaseLauncher.start_research(mission)
          end
      end
    else
      {:error, :no_sector_assigned} ->
        # Fail the mission so it doesn't stall forever in "pending"
        Logger.warning("Quest #{mission_id} has no sector and auto-assign failed")
        fail_quest(mission_id, "No sector assigned and auto-assign failed")

      {:error, :all_providers_down} ->
        # Don't fail the mission — leave it pending so it can be retried when providers recover
        Logger.warning("Quest #{mission_id} paused: all LLM providers have open circuit breakers")

        GiTF.Observability.Alerts.dispatch_webhook(
          :factory_paused,
          "All LLM providers down — mission #{mission_id} queued for retry"
        )

        {:error, :all_providers_down}

      error ->
        error
    end
  end

  @doc """
  Get mission status with phase information.
  """
  @spec get_quest_status(String.t()) :: {:ok, map()} | {:error, term()}
  def get_quest_status(mission_id) do
    with {:ok, mission} <- GiTF.Missions.get(mission_id) do
      transitions = GiTF.Missions.get_phase_transitions(mission_id)
      artifacts = Map.get(mission, :artifacts, %{})

      status = %{
        mission: mission,
        current_phase: Map.get(mission, :current_phase, "pending"),
        phase_history: transitions,
        completed_phases: Map.keys(artifacts),
        artifacts_summary: PhaseLauncher.summarize_artifacts(artifacts),
        jobs_created: length(mission.ops) > 0
      }

      {:ok, status}
    end
  end

  @doc """
  Approve the selected design and advance to planning.

  If `override_strategy` is given (e.g. "minimal"), overrides the AI's
  selection before promoting. Otherwise uses the review artifact's pick.
  """
  @spec approve_design(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def approve_design(mission_id, override_strategy \\ nil) do
    with {:ok, mission} <- GiTF.Missions.get(mission_id),
         :ok <- DesignBoard.validate_design_phase(mission) do
      review = GiTF.Missions.get_artifact(mission_id, "review") || %{}

      review =
        if override_strategy do
          updated = Map.put(review, "selected_design", override_strategy)
          GiTF.Missions.store_artifact(mission_id, "review", updated)
          updated
        else
          review
        end

      DesignBoard.promote_selected_design(mission_id, review)
      {:ok, mission} = GiTF.Missions.get(mission_id)
      PhaseLauncher.start_planning(mission)
    end
  end

  @doc """
  Max redesign iterations for `sector_id`. The policy lives with the
  design tournament (`GiTF.Major.DesignBoard.max_redesign_for/1`); kept
  here as a delegate because `GiTF.Workflow.Advancer` and the review
  phase have long referred to it by this name.
  """
  defdelegate max_redesign_for(sector_id), to: DesignBoard

  @doc """
  Returns the ordered list of pipeline phases.
  """
  @spec phases() :: [String.t()]
  def phases, do: @phases

  @doc """
  Public dispatch hook for `GiTF.Phases.Default` and the workflow-DSL
  orchestrator path. Maps a phase id to its `start_<phase>/1` function on
  `GiTF.Major.PhaseLauncher` so the workflow can drive phase advancement
  without circular module references.
  """
  @spec dispatch_phase(String.t(), map()) ::
          {:ok, atom() | tuple()} | {:error, term()}
  def dispatch_phase(phase_id, mission) do
    case Map.fetch(PhaseLauncher.phase_starters(), phase_id) do
      {:ok, starter} -> starter.(mission)
      :error -> {:error, {:unknown_phase, phase_id}}
    end
  end

  # -- The journey -------------------------------------------------------------

  @doc """
  Advance mission to next phase if current phase is complete.

  Called by the Major when a ghost completes. Checks if the current phase's
  artifact exists, and if so, transitions to the next phase.
  """
  @spec advance_quest(String.t()) :: {:ok, String.t()} | {:error, term()}
  def advance_quest(mission_id) do
    # Serialize concurrent advances for the same mission (waggle handler,
    # resume_active_quests, advance_stuck_mission_phases can all race).
    # :skip on contention because the other caller is already doing the work.
    case GiTF.MissionLock.with_lock(
           {:advance, mission_id},
           [on_contention: :skip],
           fn -> do_advance_quest(mission_id) end
         ) do
      # Lock contention — another process is already advancing this mission.
      # Return a distinct atom so callers don't confuse this with a real phase result.
      :ok -> {:contended, mission_id}
      other -> other
    end
  end

  # The three gates every advance passes before the journey resumes: is the
  # mission still alive, is it still within its time, is it still within its
  # money. `Lifecycle` owns all three judgements; this function owns what
  # happens when one of them says no.
  defp do_advance_quest(mission_id) do
    with {:ok, mission} <- GiTF.Missions.get(mission_id) do
      cond do
        # GATE 1 — the dead stay dead. Terminal missions are DONE. Advancing
        # them resurrected closed missions all day (run 17 was halted,
        # closed, and came back spawning fix ghosts; the advance log spammed
        # 'status=failed' missions every tick since msn-bf61a1). Nothing
        # downstream of a terminal status may schedule work. ("completed"
        # stays advanceable for async post-processing — scoring has its own
        # failure path.)
        mission.status in ["failed", "closed"] ->
          {:ok, :terminal}

        # GATE 2 — the clock.
        Lifecycle.quest_timed_out?(mission) ->
          halt_on_timeout(mission_id)

        # GATE 3 — the meter.
        Lifecycle.over_budget?(mission) ->
          halt_on_budget(mission_id, mission)

        # All gates clear: walk one more leg of the journey.
        true ->
          advance_mission_phase(mission)
      end
    end
  end

  defp halt_on_timeout(mission_id) do
    timeout_h = Lifecycle.max_quest_age_hours()
    Logger.warning("Quest #{mission_id} exceeded #{timeout_h}h max age, force-completing")

    GiTF.Observability.Alerts.dispatch_webhook(
      :quest_timeout,
      "Quest #{mission_id} force-completed after #{timeout_h}h timeout",
      dedup_key: "quest_timeout:#{mission_id}"
    )

    fail_quest(mission_id, "Quest timed out after #{timeout_h}h")
  end

  defp halt_on_budget(mission_id, mission) do
    case Lifecycle.mission_budget_snapshot(mission) do
      {:ok, {cap, spent}} ->
        Logger.warning(
          "Quest #{mission_id} exceeded budget cap ($#{Float.round(cap, 2)}): spent $#{Float.round(spent, 4)} — failing"
        )

        GiTF.Observability.Alerts.dispatch_webhook(
          :budget_exceeded,
          "Quest #{mission_id} spent $#{Float.round(spent, 4)} (cap $#{Float.round(cap, 2)})",
          dedup_key: "budget_exceeded:#{mission_id}"
        )

        fail_quest(
          mission_id,
          "Budget exceeded: spent $#{Float.round(spent, 4)} of $#{Float.round(cap, 2)} cap"
        )

      {:error, reason} ->
        # The budget could not be COMPUTED. Failing the quest would
        # destroy work over a bookkeeping glitch; advancing would
        # spend uncapped. Hold in place and page the operator.
        Logger.error(
          "Quest #{mission_id}: budget unverifiable (#{reason}) — holding, not advancing"
        )

        GiTF.Observability.Alerts.dispatch_webhook(
          :budget_blocked,
          "Quest #{mission_id}: budget could not be computed (#{reason}) — mission held",
          dedup_key: "budget_unverifiable:#{mission_id}"
        )

        :ok
    end
  end

  # Two maps of the same journey: a declarative workflow definition when the
  # mission carries one, and the hardcoded ladder otherwise. The bridge can
  # always fall back here, so the ladder is the ground the workflow stands on.
  #
  # The input gate is settled ABOVE the fork, on both sides of it, because it
  # belongs to neither map. Any phase may ask the operator a question it
  # cannot honestly answer itself, and the mission returns to that same phase
  # afterwards — a leg that goes sideways and comes back cannot be a step in
  # a linear itinerary. Handling it here also spares every workflow YAML from
  # declaring a phase it never routes to; one that forgot would send its held
  # missions down the Advancer's WORKFLOW DRIFT path. See `GiTF.Inquiry.Gate`.
  defp advance_mission_phase(mission) do
    phase = Map.get(mission, :current_phase, "pending")

    Logger.info(
      "Orchestrator: advancing #{mission.id} from phase=#{phase} status=#{mission.status}"
    )

    cond do
      phase == GiTF.Inquiry.gate_phase() ->
        GiTF.Inquiry.Gate.handle_result(mission)

      match?({:held, _}, GiTF.Inquiry.Gate.intercept(mission)) ->
        {:ok, GiTF.Inquiry.gate_phase()}

      WorkflowBridge.workflow_dispatch_active?(mission) ->
        WorkflowBridge.advance_via_workflow(mission, phase)

      true ->
        advance_via_legacy(mission, phase)
    end
  end

  @doc """
  THE ITINERARY. One arm per leg of the journey; each asks a persona
  whether this leg is finished and, if so, who starts the next one.

  Public (undocumented in the API sense) so `GiTF.Major.WorkflowBridge`
  can fall back to the hardcoded ladder when a workflow will not load or
  a handler raises.
  """
  def advance_via_legacy(mission, phase) do
    case phase do
      # THE DEPARTURE — a mission with a sector begins at triage (or
      # research, when triage is disabled). Without a sector it waits.
      "pending" ->
        if Map.get(mission, :sector_id) do
          if triage_enabled?() do
            PhaseLauncher.start_triage(mission)
          else
            PhaseLauncher.start_research(mission)
          end
        else
          {:ok, phase}
        end

      # TRIAGE — is there work here at all, and how big is it? Its answer
      # can skip whole legs, or end the journey before it starts.
      "triage" ->
        check_triage_and_advance(mission)

      # RESEARCH — read the ground. A low-complexity finding can still
      # revise the pipeline mode down.
      "research" ->
        check_research_and_advance(mission)

      # REQUIREMENTS — pin down what "done" means, then design against it.
      "requirements" ->
        check_and_advance(mission, "requirements", &PhaseLauncher.start_design/1)

      # DESIGN — the tournament. The board waits for the field and decides
      # whether a review is even warranted.
      "design" ->
        DesignBoard.check_design_complete(mission)

      # REVIEW — pick a winner, or send the board back to draw again.
      "review" ->
        handle_review_result(mission)

      # PLANNING — cut the chosen design into ops.
      "planning" ->
        check_and_advance(mission, "planning", &PhaseLauncher.start_implementation/1)

      # IMPLEMENTATION — the ops do the work. Failure here has its own
      # recovery ladder: fallback plan, replan, then partial credit.
      "implementation" ->
        check_implementation_complete(mission)

      # THE ENDGAME + VALIDATION — consolidation unions the ghost branches
      # (`Topology`), `Endgame` reconciles whatever did not merge clean, and
      # only then does a validation ghost judge the tree against ground truth.
      "validation" ->
        GiTF.Validation.handle_result(mission)

      # AWAITING INPUT — the journey pauses for a human MID-ROUTE and then
      # doubles back. Normally settled in `advance_mission_phase/1` above the
      # workflow fork; this arm catches the mission if a fallback ever lands
      # here directly, so the ladder cannot strand it.
      "awaiting_input" ->
        GiTF.Inquiry.Gate.handle_result(mission)

      # AWAITING APPROVAL — the journey pauses for a human.
      "awaiting_approval" ->
        GiTF.Approval.handle_result(mission)

      # SYNC — the work lands on the quest branch.
      "sync" ->
        check_and_advance(mission, "sync", &PhaseLauncher.start_simplify/1)

      # SIMPLIFY — three parallel passes (reuse, quality, efficiency) before
      # anything is published.
      "simplify" ->
        check_simplify_complete(mission)

      # PUBLISH — the mission becomes user-visibly complete here.
      "publish" ->
        check_and_advance(mission, "publish", &GiTF.Publish.after_step/1)

      # SCORING — async post-processing on an already-completed mission.
      # It gives up rather than stalling the record forever.
      "scoring" ->
        if GiTF.Scoring.post_processing_exhausted?(mission) do
          Logger.warning(
            "Quest #{mission.id}: scoring exhausted retries — marking post_processing_status=failed"
          )

          GiTF.Missions.mark_post_processing_failed(mission.id, "scoring exhausted retries")
        else
          check_and_advance(mission, "scoring", &GiTF.Scoring.finish/1)
        end

      other ->
        {:ok, other}
    end
  end

  # -- Per-leg completion checks -----------------------------------------------

  defp triage_enabled? do
    Application.get_env(:gitf, :triage_enabled, false) == true
  end

  defp check_triage_and_advance(mission) do
    artifact = GiTF.Missions.get_artifact(mission.id, "triage")

    if artifact && !Lifecycle.artifact_failed?(artifact) do
      complexity = GiTF.Triage.complexity_from_string(Map.get(artifact, "complexity")) || :complex
      skip_flags = Map.get(artifact, "skip_flags", %{}) || %{}

      inferred = Decisions.pipeline_mode_for_complexity(complexity)

      if Decisions.forced_pipeline_mode?(mission) do
        Logger.info(
          "Triage complete for #{mission.id}: keeping operator-forced pipeline mode " <>
            "#{Map.get(mission, :pipeline_mode)} over inferred #{inferred}"
        )
      else
        GiTF.Missions.update(mission.id, %{pipeline_mode: inferred})
      end

      Logger.info(
        "Triage complete for #{mission.id}: complexity=#{complexity}, skip_flags=#{inspect(skip_flags)}"
      )

      # Preflight — if triage verified the bug isn't reproducible, short-
      # circuit the entire pipeline.
      bug_reproducible = Map.get(artifact, "bug_reproducible")
      bug_evidence = Map.get(artifact, "bug_evidence", "")

      if bug_reproducible == true and bug_evidence in [nil, ""] do
        Logger.warning(
          "Quest #{mission.id}: triage emitted bug_reproducible=true with empty evidence — prompt compliance issue, proceeding cautiously"
        )
      end

      if bug_reproducible == false and GiTF.Triage.strong_no_work_evidence?(bug_evidence) do
        complete_quest_no_work_needed(mission, bug_evidence)
      else
        if bug_reproducible == false do
          Logger.warning(
            "Quest #{mission.id}: triage said bug_reproducible=false but evidence is weak " <>
              "(no SHA/file-line/test-name cite) — running the full pipeline instead"
          )
        end

        {:ok, mission} = GiTF.Missions.get(mission.id)
        effective = Decisions.effective_skip_flags(mission, skip_flags)

        if effective != skip_flags do
          Logger.info(
            "Quest #{mission.id}: operator forced the full pipeline — ignoring triage skip flags"
          )
        end

        PhaseLauncher.route_to_first_unskipped_phase(mission, effective)
      end
    else
      # No artifact yet — wait or re-spawn via the generic check.
      check_and_advance(mission, "triage", fn m ->
        PhaseLauncher.route_to_first_unskipped_phase(m, %{})
      end)
    end
  end

  defp check_research_and_advance(mission) do
    artifact = GiTF.Missions.get_artifact(mission.id, "research")

    if artifact && !Lifecycle.artifact_failed?(artifact) do
      complexity = Map.get(artifact, "complexity") || "high"

      # Guarded on the operator's explicit choice, not on the mode's current
      # value: "full" is also what start_quest writes when the fast path
      # simply wasn't eligible, and research finding low complexity is
      # exactly the signal that should be allowed to revise that.
      if complexity == "low" and not Decisions.forced_pipeline_mode?(mission) do
        Logger.info(
          "Quest #{mission.id}: Research identified low complexity, using streamlined pipeline"
        )

        GiTF.Missions.update(mission.id, %{pipeline_mode: "fast"})
        PhaseLauncher.start_requirements(mission)
      else
        Logger.info(
          "Quest #{mission.id}: Research identified high complexity, continuing deep plan"
        )

        PhaseLauncher.start_requirements(mission)
      end
    else
      Logger.warning(
        "Quest #{mission.id}: research artifact not found, falling back to check_and_advance"
      )

      check_and_advance(mission, "research", &PhaseLauncher.start_requirements/1)
    end
  end

  # The generic "is this leg done?" check: advance on a usable artifact,
  # otherwise re-spawn the phase ghost if the leg has stalled past its
  # sector-tuned timeout.
  defp check_and_advance(mission, phase, next_fn) do
    artifact = GiTF.Missions.get_artifact(mission.id, phase)

    if artifact && !Lifecycle.artifact_failed?(artifact) do
      # Refresh mission to get latest state
      {:ok, mission} = GiTF.Missions.get(mission.id)
      next_fn.(mission)
    else
      # Check if phase has been stuck too long (no artifact produced)
      transitions = GiTF.Missions.get_phase_transitions(mission.id)

      phase_start =
        transitions
        |> Enum.filter(&(Map.get(&1, :to_phase) == phase || Map.get(&1, :phase) == phase))
        |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
        |> List.first()

      if phase_start do
        age = GiTF.Clock.awake_elapsed(phase_start.inserted_at)
        timeout = PhaseLauncher.phase_timeout_for(mission.sector_id, phase)

        if age > timeout do
          # Check if there's already a running phase ghost to avoid duplicate spawning
          running_phase_job =
            Archive.find_one(:ops, fn j ->
              j.mission_id == mission.id and
                j[:op_type] == "phase" and
                j[:phase] == phase and
                j.status in ["running", "assigned"]
            end)

          running_worker =
            with %{} <- running_phase_job,
                 ghost_id when not is_nil(ghost_id) <- running_phase_job[:ghost_id],
                 {:ok, pid} <- GiTF.Ghost.Worker.lookup(ghost_id) do
              Process.alive?(pid)
            else
              _ -> false
            end

          if running_worker do
            Logger.debug(
              "Quest #{mission.id} phase #{phase} has running worker, skipping re-spawn"
            )
          else
            Logger.warning(
              "Quest #{mission.id} stuck in #{phase} for #{age}s, re-spawning phase ghost"
            )

            # Fail any stale phase ops first
            if running_phase_job do
              GiTF.Ops.fail(running_phase_job.id)
            end

            {:ok, mission} = GiTF.Missions.get(mission.id)

            case PhaseLauncher.rebuild_phase_prompt(mission, phase) do
              {prompt, model} ->
                PhaseLauncher.spawn_phase_ghost(mission, phase, prompt, model: model)

              nil ->
                Logger.info("Phase #{phase} doesn't use phase ghosts, attempting advancement")
                advance_quest(mission.id)
            end
          end
        end
      end

      {:ok, phase}
    end
  end

  defp handle_review_result(mission) do
    review = GiTF.Missions.get_artifact(mission.id, "review")

    cond do
      is_nil(review) ->
        {:ok, "review"}

      review["approved"] == true ->
        # Copy the selected design variant to the canonical "design" key
        DesignBoard.promote_selected_design(mission.id, review)
        {:ok, mission} = GiTF.Missions.get(mission.id)
        PhaseLauncher.start_planning(mission)

      true ->
        redesign_count = Map.get(mission, :redesign_count, 0)

        if redesign_count < DesignBoard.max_redesign_for(mission.sector_id) do
          Archive.update(:missions, mission.id, fn q ->
            Map.update(q, :redesign_count, 1, &(&1 + 1))
          end)

          {:ok, mission} = GiTF.Missions.get(mission.id)
          PhaseLauncher.start_design(mission)
        else
          Logger.warning(
            "Quest #{mission.id} exceeded max redesign iterations, proceeding with current design"
          )

          DesignBoard.promote_selected_design(mission.id, review)
          {:ok, mission} = GiTF.Missions.get(mission.id)
          PhaseLauncher.start_planning(mission)
        end
    end
  end

  defp check_implementation_complete(mission) do
    # Only consider non-phase implementation ops
    impl_jobs = Enum.reject(mission.ops, & &1[:phase_job])

    cond do
      impl_jobs == [] ->
        Logger.warning("Quest #{mission.id} has no implementation ops, advancing to validation")

        if Map.get(mission, :sector_id) do
          {:ok, mission} = GiTF.Missions.get(mission.id)
          PhaseLauncher.start_validation(mission)
        else
          complete_quest(mission.id)
        end

      Enum.all?(impl_jobs, &(&1.status == "done")) ->
        # Only start validation if this is a new-style mission with sector_id
        if Map.get(mission, :sector_id) do
          {:ok, mission} = GiTF.Missions.get(mission.id)
          PhaseLauncher.start_validation(mission)
        else
          # Old-style mission: just complete it directly
          complete_quest(mission.id)
        end

      Decisions.majority_failed?(impl_jobs) ->
        # >50% failed: attempt fallback plan
        attempt_fallback_plan(mission)

      Enum.any?(impl_jobs, &(&1.status in ["failed", "rejected"])) ->
        # A failed op is "resolved" if a retry sibling completed, or
        # exhausted if retry_count hit max with no retry spawned.
        retried_ok = GiTF.Ops.retried_ok_set(impl_jobs)
        failed_ops = Enum.filter(impl_jobs, &(&1.status in ["failed", "rejected"]))

        unresolved =
          Enum.reject(failed_ops, fn op ->
            Map.get(op, :retry_count, 0) >= GiTF.Ops.max_retries() or
              MapSet.member?(retried_ok, op.id)
          end)

        cond do
          unresolved == [] and Enum.all?(impl_jobs, &GiTF.Ops.resolved?(&1, retried_ok)) ->
            if Map.get(mission, :sector_id) do
              {:ok, mission} = GiTF.Missions.get(mission.id)
              PhaseLauncher.start_validation(mission)
            else
              complete_quest(mission.id)
            end

          unresolved == [] ->
            {:ok, "implementation"}

          Enum.all?(unresolved, &(Map.get(&1, :retry_count, 0) >= GiTF.Ops.max_retries())) ->
            Logger.warning(
              "Quest #{mission.id}: #{length(unresolved)} ops failed with retries exhausted, escalating"
            )

            attempt_fallback_plan(mission)

          true ->
            {:ok, "implementation"}
        end

      true ->
        {:ok, "implementation"}
    end
  end

  defp attempt_fallback_plan(mission) do
    case Planner.select_fallback_plan(mission.id) do
      {:ok, fallback} ->
        Logger.warning(
          "Quest #{mission.id}: >50% impl ops failed, switching to fallback plan (#{fallback.strategy})"
        )

        # Record tried plan atomically
        Archive.update(:missions, mission.id, fn q ->
          tried = Map.get(q, :tried_plans, [])
          current_plan = Map.get(q, :draft_plan, %{})
          Map.put(q, :tried_plans, [current_plan | tried])
        end)

        # Re-enter implementation with fallback plan
        specs = fallback.tasks

        case specs do
          tasks when is_list(tasks) and tasks != [] ->
            Planner.create_jobs_from_specs(mission.id, tasks)

            {:ok, mission} = GiTF.Missions.get(mission.id)
            spawn_implementation_jobs(mission)
            {:ok, "implementation"}

          _ ->
            Logger.warning("Fallback plan has no tasks, staying in implementation")
            {:ok, "implementation"}
        end

      {:error, :no_fallback} ->
        # Adaptive re-decomposition: replan from failure context
        replan_count = Map.get(mission, :replan_count, 0)

        if replan_count >= 2 do
          Logger.warning(
            "Quest #{mission.id}: all recovery strategies exhausted (fallback + #{replan_count} replans)"
          )

          fail_exhausted_quest(mission)
        else
          Logger.info(
            "Quest #{mission.id}: no fallback plans, attempting replan (#{replan_count + 1}/2)"
          )

          # Bump replan count atomically before attempting
          Archive.update(:missions, mission.id, fn q ->
            Map.update(q, :replan_count, 1, &(&1 + 1))
          end)

          with {:ok, replan} <- Planner.replan_from_failures(mission.id),
               tasks when is_list(tasks) and tasks != [] <- replan.tasks do
            Planner.create_jobs_from_specs(mission.id, tasks)
            {:ok, mission} = GiTF.Missions.get(mission.id)
            spawn_implementation_jobs(mission)
            {:ok, "implementation"}
          else
            {:error, reason} ->
              Logger.warning("Replan failed for mission #{mission.id}: #{inspect(reason)}")
              fail_exhausted_quest(mission)

            _ ->
              Logger.warning("Replan produced no tasks for mission #{mission.id}")
              fail_exhausted_quest(mission)
          end
        end
    end
  end

  defp fail_exhausted_quest(mission) do
    Logger.warning(
      "Quest #{mission.id} implementation exhausted — all plans, fallbacks, and replans failed"
    )

    # Collect what DID succeed for partial credit
    impl_jobs = Enum.reject(mission.ops, & &1[:phase_job])
    done_count = Enum.count(impl_jobs, &(&1.status == "done"))
    total_count = length(impl_jobs)

    GiTF.Missions.store_artifact(mission.id, "implementation_exhausted", %{
      "reason" => "All recovery strategies exhausted",
      "completed_jobs" => done_count,
      "total_jobs" => total_count,
      "replan_count" => Map.get(mission, :replan_count, 0)
    })

    if done_count > 0 do
      # Some ops succeeded — attempt validation of partial work
      Logger.info(
        "Quest #{mission.id}: #{done_count}/#{total_count} ops completed, attempting partial validation"
      )

      {:ok, mission} = GiTF.Missions.get(mission.id)
      PhaseLauncher.start_validation(mission)
    else
      # Nothing succeeded — fail the mission
      fail_quest(mission.id, "Implementation exhausted: all plans failed")

      GiTF.Observability.Alerts.dispatch_webhook(
        :quest_exhausted,
        "Quest #{mission.id} failed: all implementation strategies exhausted",
        dedup_key: "quest_exhausted:#{mission.id}"
      )

      {:ok, "completed"}
    end
  end

  defp check_simplify_complete(mission) do
    simplify_ops =
      Enum.filter(mission.ops, fn op ->
        Map.get(op, :phase) == "simplify"
      end)

    if simplify_ops == [] do
      # No simplify ops yet — still spawning
      {:ok, "simplify"}
    else
      all_done = Enum.all?(simplify_ops, &(&1.status in ["done", "failed"]))

      if all_done do
        # Collect findings from each agent
        findings =
          simplify_ops
          |> Enum.filter(&(&1.status == "done"))
          |> Enum.map(fn op ->
            strategy = ModelPolicy.op_strategy(op)
            artifact = GiTF.Missions.get_artifact(mission.id, "simplify_#{strategy}")
            %{focus: strategy, result: artifact}
          end)
          |> Enum.reject(&is_nil(&1.result))

        GiTF.Missions.store_artifact(mission.id, "simplify", %{
          "agents" => Enum.map(findings, & &1.focus),
          "completed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

        {:ok, mission} = GiTF.Missions.get(mission.id)
        GiTF.Publish.start(mission)
      else
        {:ok, "simplify"}
      end
    end
  end

  # -- Op seeding --------------------------------------------------------------

  @doc false
  # Delegates to Major's priority-aware scheduler instead of bypassing it.
  # The scheduler will pick up pending implementation ops in priority order,
  # respecting ghost slot limits and budget checks. Public so
  # `GiTF.Validation.attempt_fixes/3` can kick a fresh impl op when no
  # implementation shell is available for the fix ghost.
  def spawn_implementation_jobs(_mission) do
    case Process.whereis(GiTF.Major) do
      pid when is_pid(pid) -> send(pid, :spawn_ready_jobs)
      nil -> Logger.warning("Orchestrator: Major process not found, cannot trigger spawn")
    end
  end

  @doc false
  # The idempotency guard for op seeding. Public so
  # `GiTF.Major.PhaseLauncher` can consult it before creating the op set.
  def impl_ops_exist?(mission_id) do
    # `by_index` is O(k) on the per-mission ops bucket; the predicate
    # then short-circuits at the first non-phase op. The previous
    # `filter |> any?` form re-scanned every op in the Archive on
    # every advance-loop tick.
    Archive.by_index(:ops, :mission_id, mission_id)
    |> Enum.any?(&(&1[:phase_job] in [nil, false]))
  end

  # -- The end of the journey --------------------------------------------------

  @doc false
  # Public so `GiTF.Major.DesignBoard` can end a mission whose entire
  # design field failed.
  def fail_quest(mission_id, reason) do
    GiTF.Telemetry.set_span_error(reason)
    GiTF.Telemetry.end_current_span()

    # Classify failure and store structured info on mission record
    failure_info = classify_mission_failure(mission_id, reason)
    GiTF.Missions.update(mission_id, %{failure_info: failure_info})

    # Generate post-mortem before rolling back
    case GiTF.Missions.get(mission_id) do
      {:ok, mission} -> generate_post_mortem(mission, reason)
      _ -> :ok
    end

    # Rollback worktree if mission has a sector
    with {:ok, %{sector_id: sid}} when is_binary(sid) <- GiTF.Missions.get(mission_id),
         %{path: path} when is_binary(path) <- Archive.get(:sectors, sid) do
      Logger.info("Quest #{mission_id} failed: non-destructive sector cleanup at #{path}")
      # Never reset --hard / clean -fd the shared sector repo — it may hold a
      # human's uncommitted work. Abort any in-progress merge, else stash.
      GiTF.Git.safe_rollback(path, mission_id)
    else
      _ -> :ok
    end

    # Feed the learning loop — analyze failed ops
    Lifecycle.ingest_failure_outcome(mission_id)

    # Atomically set current_phase="completed" + status="failed" so a crash
    # between writes can't leave the mission inconsistent.
    GiTF.Missions.fail_quest(mission_id, reason)

    GiTF.Observability.Alerts.dispatch_webhook(
      :quest_failed,
      "Quest #{mission_id} lost in the net: #{reason}"
    )

    # Record failure outcome in the Ledger
    case GiTF.Missions.get(mission_id) do
      {:ok, mission} -> GiTF.Ledger.record(mission)
      _ -> :ok
    end

    {:ok, "failed"}
  end

  defp classify_mission_failure(mission_id, reason) do
    {current_phase, failed_ops} =
      case GiTF.Missions.get(mission_id) do
        {:ok, m} ->
          failed_ids =
            for op <- m.ops, op.status == "failed", do: op.id

          {Map.get(m, :current_phase, "unknown"), failed_ids}

        _ ->
          {"unknown", []}
      end

    %{
      failure_type: Lifecycle.classify_reason(reason),
      failure_phase: current_phase,
      failure_reason: reason,
      failed_op_ids: failed_ops,
      classified_at: DateTime.utc_now()
    }
  rescue
    _ ->
      %{
        failure_type: :unknown,
        failure_phase: "unknown",
        failure_reason: reason,
        failed_op_ids: [],
        classified_at: DateTime.utc_now()
      }
  end

  defp generate_post_mortem(mission, reason) do
    case Archive.get(:sectors, mission.sector_id) do
      %{path: path} when is_binary(path) ->
        if File.dir?(path) do
          content = """
          # POST MORTEM: #{mission.name}

          **Status:** FAILED
          **Reason:** #{reason}
          **Timestamp:** #{DateTime.utc_now()}
          **Mission ID:** #{mission.id}
          **Goal:** #{mission.goal}

          ## Timeline

          #{Enum.map_join(GiTF.Missions.get_phase_transitions(mission.id), "\n", fn t -> "- #{t.from_phase} -> #{t.to_phase}: #{t.reason}" end)}

          ## Failed Ops

          #{Enum.filter(mission.ops, &(&1.status == "failed")) |> Enum.map_join("\n", fn j -> "- **#{j.title}**: #{j.audit_result || "Crashed"}" end)}

          ---
          *Worktree has been rolled back to a clean state.*
          """

          filename = "POST_MORTEM_#{mission.id}.md"
          post_mortem_path = Path.join(path, filename)
          post_mortem_tmp = post_mortem_path <> ".tmp"
          File.write!(post_mortem_tmp, content)
          File.rename!(post_mortem_tmp, post_mortem_path)
          Logger.info("Generated post-mortem for quest #{mission.id} at #{path}/#{filename}")
        end

      _ ->
        :ok
    end
  rescue
    e -> Logger.warning("Failed to generate post-mortem: #{Exception.message(e)}")
  end

  defp complete_quest(mission_id) do
    case GiTF.Missions.get(mission_id) do
      {:ok, mission} ->
        # Verify the mission actually produced code changes before completing.
        impl_ops = Enum.reject(mission.ops || [], & &1[:phase_job])
        total_files = impl_ops |> Enum.map(&(&1[:files_changed] || 0)) |> Enum.sum()

        if impl_ops != [] and total_files == 0 do
          Logger.warning(
            "Quest #{mission_id}: no implementation ops produced file changes — marking as failed"
          )

          fail_quest(mission_id, "No code changes produced by any implementation op")
        else
          do_complete_quest(mission)
        end

      {:error, _} ->
        fail_quest(mission_id, "Mission not found at completion")
    end
  end

  @doc false
  # Triage short-circuit: bug not reproducible in current code. Mission is
  # user-visible completed with an explanatory artifact. No impl/validation/
  # sync/simplify/scoring runs — there's literally nothing to do.
  #
  # `@doc false def` so `GiTF.Phases.Triage.terminal/3` can call it for the
  # workflow path (`next: [{when: artifact.no_work_needed == true, then: end}]`).
  def complete_quest_no_work_needed(mission, evidence) do
    Logger.info(
      "Quest #{mission.id}: triage verified bug not reproducible — #{inspect(evidence)}"
    )

    GiTF.Missions.store_artifact(mission.id, "preflight", %{
      "bug_reproducible" => false,
      "evidence" => evidence,
      "completed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "resolution" => "no_work_needed"
    })

    GiTF.Telemetry.emit([:gitf, :mission, :no_work_needed], %{}, %{
      mission_id: mission.id,
      evidence: evidence
    })

    GiTF.Telemetry.end_current_span()

    # Use Missions.complete_quest so status is set unconditionally — the
    # transition_phase + update_status! pair won't promote a mission with
    # only a completed phase op (no impl ops) past its initial "pending"
    # status, leaving it stuck.
    with {:ok, _} <-
           GiTF.Missions.complete_quest(
             mission.id,
             "Triage verified bug not reproducible"
           ) do
      GiTF.Observability.Alerts.dispatch_webhook(
        :quest_completed,
        "Quest #{mission.id} completed — no work needed (#{evidence})"
      )

      case GiTF.Missions.get(mission.id) do
        {:ok, updated} -> GiTF.Ledger.record(updated)
        _ -> :ok
      end

      {:ok, "completed"}
    end
  end

  defp do_complete_quest(mission) do
    GiTF.Telemetry.end_current_span()

    # Use Missions.complete_quest rather than transition_phase + update_status!
    # so we can recover from an intermediate `fail_quest` (e.g. a transient
    # fix-op crash that fired fail_quest before a later fix attempt succeeded).
    # transition_phase + update_status! both respect terminal "failed" and
    # would leave the mission stuck in that state even though the work landed.
    if mission.status == "failed" do
      Logger.info(
        "Quest #{mission.id}: recovering status from 'failed' to 'completed' — " <>
          "intermediate failure was resolved by subsequent ops"
      )
    end

    with {:ok, _} <-
           GiTF.Missions.complete_quest(mission.id, "All phases complete") do
      GiTF.Observability.Alerts.dispatch_webhook(
        :quest_completed,
        "Quest #{mission.id} completed successfully"
      )

      if mission.sector_id && GiTF.Debrief.enabled?(mission.sector_id) do
        GiTF.Debrief.start_review(mission.id)
      end

      cleanup_mission_branch(mission)

      # Record outcome in the Ledger for orchestration tracking
      case GiTF.Missions.get(mission.id) do
        {:ok, updated} -> GiTF.Ledger.record(updated)
        _ -> :ok
      end

      {:ok, "completed"}
    end
  end

  @doc false
  # Public so `GiTF.Scoring.finish/1` can reap a mission's ghost
  # worktrees + branches without reaching back through the orchestrator's
  # private API. Still called internally from
  # `complete_quest_no_work_needed/2` for the triage short-circuit path.
  def cleanup_mission_branch(mission) do
    mission_id = mission.id
    sector_id = mission.sector_id

    Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
      try do
        with {:ok, sector} <- GiTF.Sector.get(sector_id) do
          cleanup_mission_shells(mission_id, sector)
          Topology.maybe_delete_mission_branch(mission_id, sector)
        end
      rescue
        e ->
          Logger.warning("Failed to cleanup mission for #{mission_id}: #{Exception.message(e)}")
      end
    end)
  end

  # Removes ghost worktrees + branches for every shell created by this
  # mission. Runs on mission completion regardless of sync strategy —
  # ghost worktrees are single-use and always safe to reap.
  defp cleanup_mission_shells(mission_id, _sector) do
    ops = GiTF.Ops.list(mission_id: mission_id)

    shell_ids =
      ops
      |> Enum.map(& &1[:shell_id])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.each(shell_ids, fn shell_id ->
      case GiTF.Shell.remove(shell_id, force: true) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.debug("Shell #{shell_id} cleanup skipped: #{inspect(reason)}")
      end
    end)

    if shell_ids != [] do
      Logger.info("Quest #{mission_id}: reaped #{length(shell_ids)} ghost shells")
    end
  end

  # -- Admission control -------------------------------------------------------

  defp budget_preflight(mission_id) do
    case GiTF.Budget.global_check() do
      {:ok, _remaining} ->
        budget_preflight_mission(mission_id)

      {:error, :daily_budget_exceeded, spent} ->
        detail = GiTF.Budget.limit_description(spent)
        Logger.warning("Quest #{mission_id} blocked: factory usage limit reached (#{detail})")

        GiTF.Observability.Alerts.dispatch_webhook(
          :budget_blocked,
          "Factory usage limit reached (#{detail}) — blocking new missions"
        )

        {:error, :daily_budget_exceeded}
    end
  rescue
    e ->
      # Fail-closed: a budget check we cannot complete must NOT admit work.
      Logger.warning(
        "Budget preflight crashed for #{mission_id}: #{Exception.message(e)} — blocking"
      )

      {:error, :budget_check_failed}
  end

  defp budget_preflight_mission(mission_id) do
    case GiTF.Budget.preflight_check(mission_id) do
      :ok ->
        :ok

      {:warn, estimated, remaining} ->
        Logger.warning(
          "Quest #{mission_id} budget tight: estimated $#{Float.round(estimated, 2)} vs $#{Float.round(remaining, 2)} remaining"
        )

        GiTF.Observability.Alerts.dispatch_webhook(
          :budget_warning,
          "Quest #{mission_id} budget tight: ~$#{Float.round(estimated, 2)} needed, $#{Float.round(remaining, 2)} remaining"
        )

        :ok

      {:error, :would_exceed, estimated, remaining} ->
        Logger.warning(
          "Quest #{mission_id} would exceed budget: estimated $#{Float.round(estimated, 2)} vs $#{Float.round(remaining, 2)} remaining"
        )

        GiTF.Observability.Alerts.dispatch_webhook(
          :budget_blocked,
          "Quest #{mission_id} blocked: ~$#{Float.round(estimated, 2)} needed but only $#{Float.round(remaining, 2)} remaining"
        )

        {:error, :budget_would_exceed}
    end
  rescue
    e ->
      # Fail-closed: an unverifiable budget must not admit work.
      Logger.warning(
        "Budget preflight check failed for #{mission_id}: #{Exception.message(e)} — blocking"
      )

      {:error, :budget_check_failed}
  end

  defp provider_preflight do
    priority = GiTF.Runtime.ProviderManager.provider_priority()
    open = GiTF.Runtime.ProviderCircuit.open_providers()

    if length(open) >= length(priority) and length(priority) > 0 do
      {:error, :all_providers_down}
    else
      :ok
    end
  rescue
    e ->
      Logger.warning("Provider preflight check failed: #{Exception.message(e)}, allowing")
      :ok
  end

  defp validate_quest_ready(mission) do
    cond do
      is_nil(Map.get(mission, :sector_id)) ->
        # Try to assign the default sector
        case auto_assign_sector(mission) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      Map.get(mission, :status) not in ["pending", "active", "planning"] ->
        {:error, :mission_not_pending}

      true ->
        :ok
    end
  end

  defp auto_assign_sector(mission) do
    sectors = GiTF.Sector.list()

    case sectors do
      [] ->
        {:error, :no_sector_assigned}

      [single] ->
        # Only one sector — auto-assign it
        case GiTF.Archive.update(:missions, mission.id, fn record ->
               Map.put(record, :sector_id, single.id)
             end) do
          {:ok, _} ->
            Logger.info("Auto-assigned sector #{single.name} to mission #{mission.id}")
            :ok

          _ ->
            {:error, :no_sector_assigned}
        end

      _multiple ->
        # Multiple sectors — try to use the current default
        case GiTF.Sector.current() do
          {:ok, current} ->
            case GiTF.Archive.update(:missions, mission.id, fn record ->
                   Map.put(record, :sector_id, current.id)
                 end) do
              {:ok, _} ->
                Logger.info(
                  "Auto-assigned current sector #{current.name} to mission #{mission.id}"
                )

                :ok

              _ ->
                {:error, :no_sector_assigned}
            end

          _ ->
            {:error, :no_sector_assigned}
        end
    end
  end
end
