defmodule GiTF.Major.Orchestrator do
  @moduledoc """
  Major's orchestration capabilities for the expert-driven pipeline.

  Manages the full phase pipeline:
  pending → research → requirements → design → review → planning → implementation → validation → completed

  Each phase spawns a ghost that produces a structured JSON artifact stored
  on the mission record. When a phase ghost's "job_complete" link_msg arrives,
  the Major calls `advance_quest`, which checks for the artifact and
  spawns the next phase's ghost.
  """

  require Logger

  alias GiTF.Archive
  alias GiTF.Major.{FastPath, PhasePrompts, Planner}
  alias GiTF.Major.Orchestrator.Decisions

  # Scoring is async post-processing that runs after publish. The mission is
  # user-visibly `status: "completed"` once publish lands; scoring + learning
  # (`ingest_mission_outcome`) continue in the background while
  # `post_processing_status` reflects their state. See `GiTF.Publish.start/1`.
  @phases ~w(triage research requirements design review planning implementation validation awaiting_approval sync simplify publish scoring)
  @default_max_redesign 2

  # Post-processing scoring gives up after this many failed scoring ops —
  # user already sees "completed", so endless retries waste budget.

  alias GiTF.Config.Provider, as: Config

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
          start_implementation(mission)

        true ->
          if triage_enabled?() do
            start_triage(mission)
          else
            start_research(mission)
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
        artifacts_summary: summarize_artifacts(artifacts),
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
         :ok <- validate_design_phase(mission) do
      review = GiTF.Missions.get_artifact(mission_id, "review") || %{}

      review =
        if override_strategy do
          updated = Map.put(review, "selected_design", override_strategy)
          GiTF.Missions.store_artifact(mission_id, "review", updated)
          updated
        else
          review
        end

      promote_selected_design(mission_id, review)
      {:ok, mission} = GiTF.Missions.get(mission_id)
      start_planning(mission)
    end
  end

  @doc """
  Reject the current designs and trigger a redesign iteration.

  Returns `{:error, :max_redesigns}` if the limit has been reached.
  """
  @spec reject_design(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def reject_design(mission_id, reason) do
    with {:ok, mission} <- GiTF.Missions.get(mission_id),
         :ok <- validate_design_phase(mission) do
      redesign_count = Map.get(mission, :redesign_count, 0)

      if redesign_count < max_redesign_for(mission.sector_id) do
        Archive.update(:missions, mission_id, fn q ->
          q
          |> Map.update(:redesign_count, 1, &(&1 + 1))
          |> Map.put(:redesign_reason, reason)
        end)

        {:ok, mission} = GiTF.Missions.get(mission_id)
        start_design(mission)
      else
        {:error, :max_redesigns}
      end
    end
  end

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

  defp do_advance_quest(mission_id) do
    with {:ok, mission} <- GiTF.Missions.get(mission_id) do
      cond do
        # Terminal missions are DONE. Advancing them resurrected closed
        # missions all day (run 17 was halted, closed, and came back
        # spawning fix ghosts; the advance log spammed 'status=failed'
        # missions every tick since msn-bf61a1). Nothing downstream of a
        # terminal status may schedule work. ("completed" stays advanceable
        # for async post-processing — scoring has its own failure path.)
        mission.status in ["failed", "closed"] ->
          {:ok, :terminal}

        quest_timed_out?(mission) ->
          timeout_h = max_quest_age_hours()
          Logger.warning("Quest #{mission_id} exceeded #{timeout_h}h max age, force-completing")

          GiTF.Observability.Alerts.dispatch_webhook(
            :quest_timeout,
            "Quest #{mission_id} force-completed after #{timeout_h}h timeout",
            dedup_key: "quest_timeout:#{mission_id}"
          )

          fail_quest(mission_id, "Quest timed out after #{timeout_h}h")

        over_budget?(mission) ->
          {cap, spent} = mission_budget_snapshot(mission)

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

        true ->
          advance_mission_phase(mission)
      end
    end
  end

  defp over_budget?(mission) do
    status = Map.get(mission, :status, "pending")
    phase = Map.get(mission, :current_phase, "pending")

    # Skip the check once the mission is user-visibly done — post-processing
    # cost is bounded by the scoring-failure cap, not the mission budget.
    if status == "completed" or phase in ["completed", "awaiting_approval", "pending"] do
      false
    else
      {cap, spent} = mission_budget_snapshot(mission)
      spent > cap
    end
  end

  defp mission_budget_snapshot(mission) do
    # Resolution order: per-mission cap, explicit [major] override, then the
    # provider-scoped mission budget ([costs.provider_mission_budgets] —
    # cli/Max caps are notional, so they're set generous). This used to
    # hard-default to $20 without ever consulting Budget.config_budget():
    # invisible while CLI costs booked as model-unknown pocket change, but
    # the moment per-model booking recorded REAL notional costUSD, a healthy
    # run 24 hit $22.50 by validation round 1 and was killed mid-fix-loop
    # against config that said $40.
    cap =
      Map.get(mission, :cost_cap_usd) ||
        Config.get([:major, :mission_cost_cap_usd]) ||
        GiTF.Budget.config_budget()

    spent = GiTF.Costs.for_quest(mission.id) |> GiTF.Costs.total()
    {cap * 1.0, spent}
  rescue
    # spent=0 means the guard can't fire on a failed lookup; the cap value
    # is inert here.
    _ -> {20.0, 0.0}
  end

  defp quest_timed_out?(mission) do
    case mission[:inserted_at] do
      %DateTime{} = started ->
        # Awake hours, not wall hours — idle-stop sleeps must not count
        # toward a mission's age (a wake was force-completing the queue).
        hours = GiTF.Clock.awake_elapsed(started) / 3600
        phase = Map.get(mission, :current_phase, "pending")
        status = Map.get(mission, :status, "pending")
        # Don't timeout missions that are completed or awaiting approval.
        # Also skip missions that are user-visibly completed but still running
        # async post-processing (status="completed" with phase="scoring") —
        # post-processing has its own failure path that doesn't regress status.
        status != "completed" and
          phase not in ["completed", "awaiting_approval", "pending"] and
          hours > max_quest_age_hours()

      _ ->
        false
    end
  end

  defp advance_mission_phase(mission) do
    phase = Map.get(mission, :current_phase, "pending")

    Logger.info(
      "Orchestrator: advancing #{mission.id} from phase=#{phase} status=#{mission.status}"
    )

    if workflow_dispatch_active?(mission) do
      advance_via_workflow(mission, phase)
    else
      advance_via_legacy(mission, phase)
    end
  end

  defp workflow_dispatch_active?(mission) do
    Application.get_env(:gitf, :workflow_dsl_enabled, true) == true and
      is_binary(Map.get(mission, :workflow_id)) and
      Map.get(mission, :workflow_id) != ""
  end

  defp advance_via_workflow(mission, phase) do
    case GiTF.Workflow.resolve(mission.workflow_id, mission.sector_id) do
      {:ok, workflow} ->
        decision = GiTF.Workflow.Advancer.decide(mission, workflow)

        Logger.info(
          "Orchestrator: workflow=#{workflow.name} decision=#{inspect(decision)} for #{mission.id}@#{phase}"
        )

        handle_workflow_decision(decision, mission, phase, workflow)

      {:error, reason} ->
        Logger.warning(
          "Workflow #{mission.workflow_id} did not load for mission #{mission.id}: #{inspect(reason)}; legacy"
        )

        advance_via_legacy(mission, phase)
    end
  end

  defp handle_workflow_decision({:wait, p}, _mission, _phase, _wf), do: {:ok, p}

  defp handle_workflow_decision({:dispatch, next_id}, mission, _phase, workflow),
    do: dispatch_via_handler(workflow, next_id, mission)

  defp handle_workflow_decision(:complete, mission, _phase, workflow) do
    # Give the just-ended phase's handler first refusal — e.g.,
    # `Phases.Scoring.terminal(:complete)` calls `mark_post_processing_done/1`
    # since the mission was already user-visibly completed by
    # `Phases.Publish.before_advance/3`, so the standard `complete_quest`
    # would be wrong here.
    case GiTF.Workflow.Advancer.invoke_terminal(mission, workflow, :complete) do
      {:ok, :handled} ->
        {:ok, "completed"}

      :default ->
        GiTF.Missions.complete_quest(mission.id, "workflow reached :end")
        {:ok, "completed"}
    end
  end

  defp handle_workflow_decision({:retry, source, target}, mission, _phase, workflow) do
    Archive.update(:missions, mission.id, fn m ->
      retries = Map.get(m, :phase_retries) || %{}
      Map.put(m, :phase_retries, Map.update(retries, source, 1, &(&1 + 1)))
    end)

    dispatch_via_handler(workflow, target, mission)
  end

  defp handle_workflow_decision({:retries_exhausted, p}, mission, _phase, workflow) do
    case GiTF.Workflow.Advancer.invoke_terminal(mission, workflow, :retries_exhausted) do
      {:ok, :handled} ->
        Logger.info("Quest #{mission.id}: workflow ended at #{p} (handler-terminated)")
        {:ok, "failed"}

      :default ->
        Logger.warning(
          "Quest #{mission.id}: workflow exhausted retries on phase=#{p}, marking failed"
        )

        # fail_quest, not a bare status write: it records the reason, moves
        # the phase to terminal, and fires the notification. Setting status
        # directly left msn-dd29a1 as failed/validation/no-reason — the
        # reviewer was never told, and the Janitor re-advanced the record
        # every 3 minutes because its phase never became terminal.
        GiTF.Missions.fail_quest(
          mission.id,
          "workflow exhausted retries on phase #{p}"
        )

        {:ok, "failed"}
    end
  end

  # Workflow drift (phase id no longer defined — deploy renamed it, or
  # workflow switched mid-mission): HOLD in the current phase. Neither
  # rewinding nor the legacy path is safe here; the Advancer already
  # alerted the operator.
  defp handle_workflow_decision({:error, {:workflow_drift, _}}, _mission, phase, _wf),
    do: {:ok, phase}

  defp handle_workflow_decision({:error, reason}, mission, phase, _wf) do
    Logger.warning(
      "Workflow dispatch error for mission #{mission.id}: #{inspect(reason)}; falling back to legacy"
    )

    advance_via_legacy(mission, phase)
  end

  # Dispatches `phase_id` for a workflow-path mission. Prefers the
  # workflow phase's `handler:` (a `GiTF.Phase` implementation's `start/3`)
  # so the handler can run logic legacy keeps in `start_<phase>/1`; falls
  # back to `dispatch_phase/2` (the legacy starter map) when no handler
  # is configured or the module hasn't loaded a `start/3`.
  defp dispatch_via_handler(workflow, phase_id, mission) do
    case GiTF.Workflow.phase(workflow, phase_id) do
      {:ok, %GiTF.Workflow.Phase{handler: handler} = phase_config}
      when not is_nil(handler) ->
        if Code.ensure_loaded?(handler) and function_exported?(handler, :start, 3) do
          ctx = %{workflow: workflow, sector_id: Map.get(mission, :sector_id)}

          try do
            handler.start(mission, phase_config, ctx)
          rescue
            e ->
              Logger.warning(
                "Handler #{inspect(handler)}.start/3 raised for mission #{mission.id}@#{phase_id}: " <>
                  "#{Exception.message(e)}; falling back to legacy starter"
              )

              dispatch_phase(phase_id, mission)
          end
        else
          dispatch_phase(phase_id, mission)
        end

      _ ->
        dispatch_phase(phase_id, mission)
    end
  end

  defp advance_via_legacy(mission, phase) do
    case phase do
      "pending" ->
        # Only start research if mission has a sector_id (new-style missions)
        if Map.get(mission, :sector_id) do
          if triage_enabled?() do
            start_triage(mission)
          else
            start_research(mission)
          end
        else
          {:ok, phase}
        end

      "triage" ->
        check_triage_and_advance(mission)

      "research" ->
        check_research_and_advance(mission)

      "requirements" ->
        check_and_advance(mission, "requirements", &start_design/1)

      "design" ->
        check_design_complete(mission)

      "review" ->
        handle_review_result(mission)

      "planning" ->
        check_and_advance(mission, "planning", &start_implementation/1)

      "implementation" ->
        check_implementation_complete(mission)

      "validation" ->
        GiTF.Validation.handle_result(mission)

      "awaiting_approval" ->
        GiTF.Approval.handle_result(mission)

      "sync" ->
        check_and_advance(mission, "sync", &start_simplify/1)

      "simplify" ->
        check_simplify_complete(mission)

      "publish" ->
        check_and_advance(mission, "publish", &GiTF.Publish.after_step/1)

      "scoring" ->
        # Scoring runs as async post-processing; user-visible status is
        # already "completed". If scoring fails repeatedly, give up on
        # post-processing rather than leaving the phase stuck forever.
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

  @doc """
  Returns the ordered list of pipeline phases.
  """
  @spec phases() :: [String.t()]
  def phases, do: @phases

  @doc """
  Public dispatch hook for `GiTF.Phases.Default` and the upcoming
  workflow-DSL orchestrator path (M3). Maps a phase id to its
  hardcoded `start_<phase>/1` function so the workflow can drive phase
  advancement without exposing every starter as `def`.

  Pre-M3 callers (the existing hardcoded path) continue to call the
  private `start_<phase>/1` functions directly; this dispatch exists
  so the workflow DSL can call into the same logic without circular
  module references.
  """
  @spec dispatch_phase(String.t(), map()) ::
          {:ok, atom() | tuple()} | {:error, term()}
  def dispatch_phase(phase_id, mission) do
    case Map.fetch(phase_starters(), phase_id) do
      {:ok, starter} -> starter.(mission)
      :error -> {:error, {:unknown_phase, phase_id}}
    end
  end

  defp phase_starters do
    %{
      "triage" => &start_triage/1,
      "research" => &start_research/1,
      "requirements" => &start_requirements/1,
      "design" => &start_design/1,
      "review" => &start_review/1,
      "planning" => &start_planning/1,
      "implementation" => &start_implementation/1,
      "validation" => &start_validation/1,
      "simplify" => &start_simplify/1,
      "publish" => &GiTF.Publish.start/1,
      "scoring" => &start_scoring/1,
      "awaiting_approval" => &GiTF.Approval.request/1,
      "sync" => &GiTF.Publish.merge/1
    }
  end

  # -- Phase Starters ----------------------------------------------------------

  defp triage_enabled? do
    Application.get_env(:gitf, :triage_enabled, false) == true
  end

  # Returns the canonical atom representation of the triage artifact's
  # `"complexity"` field, or nil if no triage artifact exists or the value
  # is unrecognized. The wire/JSON format is always a string; `GiTF.Triage`
  # owns the string↔atom mapping.
  defp triage_complexity(mission) do
    case GiTF.Missions.get_artifact(mission.id, "triage") do
      %{} = triage ->
        triage |> Map.get("complexity") |> GiTF.Triage.complexity_from_string()

      _ ->
        nil
    end
  end

  defp start_triage(mission) do
    sector_id = Map.get(mission, :sector_id)

    if is_nil(sector_id) do
      {:error, :no_sector_assigned}
    else
      with {:ok, _} <- GiTF.Missions.transition_phase(mission.id, "triage", "Quest started") do
        sector = Archive.get(:sectors, sector_id)
        prompt = PhasePrompts.triage_prompt(mission, sector)
        spawn_phase_ghost(mission, "triage", prompt, model: "general")
        {:ok, "triage"}
      end
    end
  end

  defp check_triage_and_advance(mission) do
    artifact = GiTF.Missions.get_artifact(mission.id, "triage")

    if artifact && !artifact_failed?(artifact) do
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

        route_to_first_unskipped_phase(mission, effective)
      end
    else
      # No artifact yet — wait or re-spawn via the generic check.
      check_and_advance(mission, "triage", fn m ->
        route_to_first_unskipped_phase(m, %{})
      end)
    end
  end

  defp route_to_first_unskipped_phase(mission, skip_flags) do
    # Read off the mission in hand — the caller re-fetched it immediately
    # before. `Missions.get_artifact/2` would deep-copy the whole record out
    # of ETS, artifacts map and all, to look at one key.
    has_design? = not is_nil(get_in(mission, [Access.key(:artifacts, %{}), "design"]))

    case Decisions.next_phase_after_triage(skip_flags, has_design?) do
      :research -> start_research(mission)
      :requirements -> start_requirements(mission)
      :design -> start_design(mission)
      :review -> start_review(mission)
      :planning -> start_planning(mission)
      :implementation -> start_implementation(mission)
    end
  end

  defp start_research(mission) do
    sector_id = Map.get(mission, :sector_id)

    if is_nil(sector_id) do
      {:error, :no_sector_assigned}
    else
      with {:ok, _} <- GiTF.Missions.transition_phase(mission.id, "research") do
        sector = Archive.get(:sectors, sector_id)
        ctx = GiTF.Intel.get_prompt_context(sector_id, "research", mission)

        prompt =
          PhasePrompts.research_prompt(mission, sector, ctx,
            complexity: triage_complexity(mission)
          )

        spawn_phase_ghost(mission, "research", prompt, model: "general")
        {:ok, "research"}
      end
    end
  end

  defp start_requirements(mission) do
    research = GiTF.Missions.get_artifact(mission.id, "research")

    with {:ok, _} <-
           GiTF.Missions.transition_phase(mission.id, "requirements") do
      ctx = GiTF.Intel.get_prompt_context(mission.sector_id, "requirements", mission)
      prompt = PhasePrompts.requirements_prompt(mission, research, ctx)
      spawn_phase_ghost(mission, "requirements", prompt, model: "general")
      {:ok, "requirements"}
    end
  end

  @design_strategies [
    %{name: "minimal", hint: "Simplest approach that satisfies the core requirements"},
    %{name: "normal", hint: "Standard implementation following existing patterns"},
    %{name: "complex", hint: "Comprehensive implementation with edge cases and extensibility"}
  ]

  defp strategies_for_complexity(research, sector_id) do
    complexity = if research, do: Map.get(research, "complexity"), else: nil

    base_count =
      case complexity do
        "moderate" -> 1
        _ -> 3
      end

    # Consult sector intelligence for strategy count adjustment
    count =
      case sector_id && GiTF.Intel.SectorProfile.get_or_compute(sector_id) do
        %{confidence: conf, recommendations: %{strategy_count: rec_count}}
        when conf in [:medium, :high] ->
          GiTF.Intel.SectorProfile.blend(rec_count, base_count, conf)

        _ ->
          base_count
      end

    count = max(1, min(count, 3))

    case count do
      1 -> [Enum.find(@design_strategies, &(&1.name == "normal"))]
      2 -> Enum.filter(@design_strategies, &(&1.name in ["normal", "complex"]))
      _ -> @design_strategies
    end
  end

  defp start_design(mission) do
    requirements = GiTF.Missions.get_artifact(mission.id, "requirements")
    research = GiTF.Missions.get_artifact(mission.id, "research")

    with {:ok, _} <- GiTF.Missions.transition_phase(mission.id, "design") do
      review = GiTF.Missions.get_artifact(mission.id, "review")

      extra_instructions =
        if is_client_facing?(mission) do
          "6. ACT AS A BEHAVIORAL SCIENTIST: This is a client-facing project. Evaluate the plan for how people might think about it and what would make it exceptionally useful. Incorporate behavioral insights into the component design."
        else
          ""
        end

      strategies =
        if FastPath.fast_mode?(mission) do
          [%{name: "minimal", hint: "Simplest approach that satisfies the core requirements"}]
        else
          strategies_for_complexity(research, mission.sector_id)
        end

      # Store strategy count so advance logic knows how many to wait for
      Archive.update(:missions, mission.id, fn q ->
        Map.put(q, :design_strategy_count, length(strategies))
      end)

      ctx = GiTF.Intel.get_prompt_context(mission.sector_id, "design", mission)

      # Spawn parallel design ghosts — count scales with complexity
      Enum.each(strategies, fn %{name: strategy_name} ->
        strategy_section = Planner.strategy_instruction(strategy_name, nil)

        base_prompt =
          if review && review["approved"] == false do
            PhasePrompts.design_prompt_with_feedback(
              mission,
              requirements,
              research,
              review,
              extra_instructions,
              ctx
            )
          else
            PhasePrompts.design_prompt(mission, requirements, research, extra_instructions, ctx)
          end

        prompt = base_prompt <> "\n" <> strategy_section <> "\n"

        spawn_phase_ghost(mission, "design", prompt,
          model: phase_model_for_complexity("design", mission),
          strategy: strategy_name
        )
      end)

      {:ok, "design"}
    end
  end

  defp start_review(mission) do
    requirements = GiTF.Missions.get_artifact(mission.id, "requirements")
    research = GiTF.Missions.get_artifact(mission.id, "research")

    # Collect all design variants (design_minimal, design_normal, design_complex)
    designs = collect_design_variants(mission.id)

    with {:ok, _} <- GiTF.Missions.transition_phase(mission.id, "review") do
      prompt = PhasePrompts.review_prompt(mission, designs, requirements, research)

      spawn_phase_ghost(mission, "review", prompt,
        model: phase_model_for_complexity("review", mission)
      )

      {:ok, "review"}
    end
  end

  # Routes design/planning/review to `general` (cheaper/faster) when triage
  # said trivial/simple/moderate. Complex and unknown keep `thinking` so we
  # don't regress on hard work.
  defp phase_model_for_complexity(phase, mission) do
    case {phase, triage_complexity(mission)} do
      {p, c} when p in ["design", "planning", "review"] and c in [:trivial, :simple, :moderate] ->
        "general"

      {p, _} when p in ["design", "planning", "review"] ->
        "thinking"

      _ ->
        "general"
    end
  end

  defp collect_design_variants(mission_id) do
    @design_strategies
    |> Enum.map(fn %{name: name} ->
      key = "design_#{name}"
      artifact = GiTF.Missions.get_artifact(mission_id, key)
      if artifact, do: {name, artifact}, else: nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
    |> case do
      designs when map_size(designs) > 0 ->
        designs

      _ ->
        # Fallback: check for a single "design" artifact (backward compat)
        case GiTF.Missions.get_artifact(mission_id, "design") do
          nil -> %{}
          design -> %{"normal" => design}
        end
    end
  end

  defp start_planning(mission) do
    design = GiTF.Missions.get_artifact(mission.id, "design")
    requirements = GiTF.Missions.get_artifact(mission.id, "requirements")
    review = GiTF.Missions.get_artifact(mission.id, "review")

    with {:ok, _} <- GiTF.Missions.transition_phase(mission.id, "planning") do
      ctx = GiTF.Intel.get_prompt_context(mission.sector_id, "planning", mission)
      prompt = PhasePrompts.planning_prompt(mission, design, requirements, review, ctx)

      spawn_phase_ghost(mission, "planning", prompt,
        model: phase_model_for_complexity("planning", mission)
      )

      {:ok, "planning"}
    end
  end

  defp start_implementation(mission) do
    planning_artifact = GiTF.Missions.get_artifact(mission.id, "planning")

    with {:ok, _} <-
           GiTF.Missions.transition_phase(mission.id, "implementation") do
      # Planning phase already scored and selected the best plan. Just
      # create ops from whatever planning artifact exists. In
      # tournament mode (`Tournament.enabled?`), the planned op list is
      # duplicated across each variant id so multiple impl ghosts can
      # work the same plan on independent branches.
      case planning_artifact do
        specs when is_list(specs) and specs != [] ->
          create_implementation_ops(mission, specs)

        _ ->
          Logger.warning("Planning artifact is not a list, falling back to synthetic planning")
          generate_synthetic_jobs(mission)
      end

      # Spawn ready ops
      {:ok, mission} = GiTF.Missions.get(mission.id)
      spawn_implementation_jobs(mission)

      GiTF.Missions.update_status!(mission.id)
      {:ok, "implementation"}
    end
  end

  # Single- or multi-variant op creation. Tournament mode stamps
  # `mission.impl_variants = ["v1", ..., "vN"]` and creates N copies of
  # the planned op list, one per variant.
  #
  # Idempotent: if any non-phase impl op already exists for the mission
  # (a concurrent advance loop or a re-dispatch beat us here) we return
  # `{:ok, :already_seeded}` instead of duplicating the op set. Without
  # this guard, double-dispatch under tournament mode silently created
  # 2N impl ops, half of which would have stale shells and never
  # complete.
  defp create_implementation_ops(mission, specs) do
    if impl_ops_exist?(mission.id) do
      {:ok, :already_seeded}
    else
      attempts = GiTF.Tournament.configured_attempts()

      if attempts > 1 do
        variant_ids = GiTF.Tournament.variant_ids(attempts)

        Archive.update(:missions, mission.id, fn record ->
          Map.put(record, :impl_variants, variant_ids)
        end)

        Logger.info(
          "Quest #{mission.id}: tournament mode — spawning #{length(variant_ids)} impl variants " <>
            "(#{Enum.join(variant_ids, ", ")})"
        )

        Planner.create_jobs_for_variants(mission.id, specs, variant_ids)
      else
        Planner.create_jobs_from_specs(mission.id, specs)
      end
    end
  end

  defp impl_ops_exist?(mission_id) do
    # `by_index` is O(k) on the per-mission ops bucket; the predicate
    # then short-circuits at the first non-phase op. The previous
    # `filter |> any?` form re-scanned every op in the Archive on
    # every advance-loop tick.
    Archive.by_index(:ops, :mission_id, mission_id)
    |> Enum.any?(&(&1[:phase_job] in [nil, false]))
  end

  defp start_validation(mission) do
    # Only short-circuit when a validation ghost is CURRENTLY in-flight —
    # that's the concurrent-advance double-spawn we must avoid. A *completed*
    # prior validation must NOT block re-validation: after a fix op the mission
    # re-enters here from implementation and needs a fresh validation ghost.
    # Guarding on "any validation op ever existed" wedged the fix loop —
    # the mission stayed in `implementation` forever, never re-validating to
    # detect exhaustion. (advance_quest is serialized per-mission via
    # MissionLock, so an in-flight check is sufficient.)
    if validation_in_flight?(mission.id) do
      {:ok, "validation"}
    else
      requirements = GiTF.Missions.get_artifact(mission.id, "requirements")
      planning = GiTF.Missions.get_artifact(mission.id, "planning")
      do_start_validation(mission, requirements, planning)
    end
  end

  defp validation_in_flight?(mission_id) do
    Archive.by_index(:ops, :mission_id, mission_id)
    |> Enum.any?(fn op ->
      op[:phase_job] == true and op[:phase] == "validation" and
        op.status in ["pending", "assigned", "running"]
    end)
  end

  defp do_start_validation(mission, requirements, planning) do
    with {:ok, _} <-
           GiTF.Missions.transition_phase(mission.id, "validation") do
      ctx = GiTF.Intel.get_prompt_context(mission.sector_id, "validation", mission)
      diff_base = detect_diff_base(mission)

      # Walk mission.ops once and bucket by variant_id (nil for
      # single-variant missions). The tournament fan-out below then
      # spawns one validation ghost per variant from its bucket without
      # re-walking the full op list per spawn.
      ops_by_variant =
        Enum.group_by(mission.ops, fn op ->
          if op[:phase_job] in [nil, false] and op.status == "done",
            do: op[:variant],
            else: :_skip
        end)
        |> Map.delete(:_skip)

      case Map.get(mission, :impl_variants) || [] do
        [] ->
          {:ok, conflicted} =
            consolidate_impl_branches(mission, Map.get(ops_by_variant, nil, []))

          changed_files = collect_changed_files(ops_by_variant, nil)

          spawn_validation_for_variant(
            mission,
            requirements,
            planning,
            ctx,
            diff_base,
            nil,
            changed_files,
            conflicted
          )

        variants ->
          # Tournament mode: one validation ghost per variant, each
          # rooted at that variant's last completed impl op so the diff
          # is variant-local. No consolidation across variants — no
          # conflict markers to surface.
          Enum.each(variants, fn variant_id ->
            changed_files = collect_changed_files(ops_by_variant, variant_id)

            spawn_validation_for_variant(
              mission,
              requirements,
              planning,
              ctx,
              diff_base,
              variant_id,
              changed_files,
              []
            )
          end)
      end

      {:ok, "validation"}
    end
  end

  defp collect_changed_files(ops_by_variant, variant_id) do
    ops_by_variant
    |> Map.get(variant_id, [])
    |> Enum.flat_map(fn op ->
      case op[:changed_files] do
        files when is_list(files) -> files
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  # Gated on :lsp_validation_enabled. Returns the `{file, [error_diag]}`
  # pairs for whatever the diagnostic cache currently holds. Falls
  # through to `[]` on any LSP error (disabled, driver missing, sector
  # unknown) so the validation prompt stays renderable.
  defp collect_lsp_diagnostics_for_validation(_mission, []), do: []

  defp collect_lsp_diagnostics_for_validation(mission, files) do
    if Application.get_env(:gitf, :lsp_validation_enabled, false) do
      case GiTF.LSP.collect_errors(mission.sector_id, files) do
        {:ok, pairs} -> pairs
        {:error, _} -> []
      end
    else
      []
    end
  end

  defp spawn_validation_for_variant(
         mission,
         requirements,
         planning,
         ctx,
         diff_base,
         variant_id,
         changed_files,
         merge_conflicts
       ) do
    lsp_diagnostics = collect_lsp_diagnostics_for_validation(mission, changed_files)
    exec_validation = run_exec_validation(mission, variant_id)

    # Main can move under a mission that takes an hour. The fix loop was
    # reconciling other people's merged work without ever being told what
    # that work was — and when the merge was clean, nothing signalled that
    # the plan might have been overtaken at all.
    base_moved =
      case GiTF.Validation.canonical_impl_shell(mission) do
        %{worktree_path: wt} -> GiTF.Drift.main_advance_summary(wt)
        _ -> nil
      end

    prompt =
      PhasePrompts.validation_prompt(mission, requirements, planning, ctx,
        diff_base: diff_base,
        changed_files: changed_files,
        lsp_diagnostics: lsp_diagnostics,
        exec_validation: exec_validation,
        merge_conflicts: merge_conflicts,
        base_moved: base_moved,
        unresolved_review: GiTF.Phases.Review.unresolved_objection(mission)
      )

    # Branch the validation worktree from the variant's impl ghost tip so
    # `git diff` against the sector main shows that variant's changes only.
    base_opts =
      case variant_base_branch(mission, variant_id) do
        nil -> impl_base_branch_opts(mission)
        base -> [base_branch: base]
      end

    opts = [model: "general"] ++ base_opts ++ if variant_id, do: [variant: variant_id], else: []
    spawn_phase_ghost(mission, "validation", prompt, opts)
  end

  # Runs the sector's validation_command in the implementation ghost's
  # worktree and returns ground truth for the validation prompt:
  # {:pass, cmd} | {:fail, cmd, output} | nil (not configured / no
  # worktree to run in). This is the ONLY place the command runs on the
  # normal pipeline — GiTF.Validator.validate is otherwise reached just
  # via the conflict-rebase path.
  defp run_exec_validation(mission, variant_id) do
    with %{validation_command: cmd} = sector when is_binary(cmd) and cmd != "" <-
           Archive.get(:sectors, mission.sector_id),
         %{worktree_path: _} = shell <- exec_validation_shell(mission, variant_id) do
      Logger.info("Running validation command for #{mission.id}: #{cmd}")

      case GiTF.Validator.run_custom_validation(
             shell,
             cmd,
             GiTF.Validator.validation_timeout_ms(sector)
           ) do
        :ok ->
          Logger.info("Validation command passed for #{mission.id}")
          {:pass, cmd}

        {:error, output} ->
          Logger.warning(
            "Validation command FAILED for #{mission.id}: #{String.slice(to_string(output), 0, 300)}"
          )

          {:fail, cmd, to_string(output)}
      end
    else
      _ -> nil
    end
  rescue
    e ->
      Logger.warning("run_exec_validation crashed for #{mission.id}: #{Exception.message(e)}")
      nil
  end

  # The exec command (typecheck + the runtime probe) MUST run in the same
  # tree the LLM validator judges and publish ships — the CANONICAL shell,
  # which is also the consolidation target. Run 31 proved why: the probe
  # passed in one worktree while the validator correctly reported
  # conflict markers in another, so a green probe said nothing about the
  # tree under judgement. Falls back to the per-variant impl shell only
  # when no canonical shell exists (tournament variants have their own).
  # Files whose content is emitted by a generator, never hand-authored.
  @generated_patterns [~r{/bindings/.*\.ts$}, ~r{\.generated\.}, ~r{/__generated__/}]

  defp generated_file?(path) do
    Enum.any?(@generated_patterns, &Regex.match?(&1, path))
  end

  # Re-run the sector's generator and stage the result. Returns the files
  # it actually rewrote; anything left is handed back to the fix loop.
  defp regenerate(worktree, files) do
    case GiTF.Sandbox.wrap_shell("npm run bindings", cd: worktree) do
      {cmd, args} ->
        case System.cmd(cmd, args, cd: worktree, stderr_to_stdout: true) do
          {_, 0} ->
            still_conflicted =
              Enum.filter(files, fn f ->
                case File.read(Path.join(worktree, f)) do
                  {:ok, body} -> String.contains?(body, "<<<<<<<")
                  _ -> true
                end
              end)

            resolved = files -- still_conflicted

            if resolved != [] do
              GiTF.Git.safe_cmd(["-C", worktree, "add" | resolved], stderr_to_stdout: true)

              GiTF.Git.safe_cmd(
                ["-C", worktree, "commit", "-m", "gitf: regenerate bindings after consolidation"],
                stderr_to_stdout: true
              )
            end

            resolved

          _ ->
            []
        end
    end
  rescue
    _ -> []
  end

  defp exec_validation_shell(mission, nil) do
    case GiTF.Validation.canonical_impl_shell(mission) do
      %{worktree_path: _} = shell -> shell
      _ -> variant_shell(mission, nil)
    end
  end

  defp exec_validation_shell(mission, variant_id), do: variant_shell(mission, variant_id)

  defp variant_shell(mission, variant_id) do
    with %{ghost_id: ghost_id} when is_binary(ghost_id) <-
           impl_op_for_variant(mission, variant_id),
         %{shell_id: shell_id} when is_binary(shell_id) <- Archive.get(:ghosts, ghost_id) do
      Archive.get(:shells, shell_id)
    else
      _ -> nil
    end
  end

  defp impl_op_for_variant(mission, nil), do: GiTF.Validation.latest_completed_impl_op(mission)

  defp impl_op_for_variant(mission, variant_id) do
    mission.ops
    |> Enum.filter(fn op ->
      op[:phase_job] in [nil, false] and op.status == "done" and op[:variant] == variant_id
    end)
    |> Enum.sort_by(& &1[:inserted_at], {:desc, DateTime})
    |> List.first()
  end

  # Returns the ghost-id-based branch for `variant_id`'s most recent
  # completed impl op, or `nil` if none / non-tournament mode.
  defp variant_base_branch(_mission, nil), do: nil

  defp variant_base_branch(mission, variant_id) do
    mission.ops
    |> Enum.filter(fn op ->
      op[:phase_job] in [nil, false] and op.status == "done" and op[:variant] == variant_id
    end)
    |> Enum.sort_by(& &1[:inserted_at], {:desc, DateTime})
    |> List.first()
    |> case do
      %{ghost_id: ghost_id} when is_binary(ghost_id) -> "ghost/#{ghost_id}"
      _ -> nil
    end
  end

  # Best-guess diff base: the sector's main branch. Falls back to "main".
  defp detect_diff_base(mission) do
    with sector_id when is_binary(sector_id) <- mission.sector_id,
         %{path: path} when is_binary(path) <- Archive.get(:sectors, sector_id),
         {:ok, branch} <- GiTF.Sync.detect_main_branch(path) do
      branch
    else
      _ -> "main"
    end
  end

  # Returns [base_branch: "ghost/<id>"] when a completed impl op exists for
  # the mission, or [] if none — in which case worktrees branch from sector
  # HEAD (the current default).
  # Merge every completed impl op's ghost branch into the LATEST completed
  # op's worktree so validation (and publish downstream) sees the UNION of
  # the mission's work. Parallel impl ops commit to per-ghost branches;
  # without this merge the validator diffed one branch and reported the
  # sibling ops' finished, type-checked work as "completely missing" —
  # three runs died at the validation wall staring at origin/main while
  # the feature sat in two branches (msn-807187, finding #17). Idempotent:
  # re-merging an already-merged branch is "Already up to date".
  #
  # A CONTENT conflict completes the merge with the conflict markers
  # committed, and the conflicted files are returned so the validation
  # prompt can direct the fix loop to reconcile them. The previous policy
  # (abort the branch's merge, let validation "report the gap") silently
  # dropped entire branches from the union: run 13 (msn-c1c654) lost the
  # whole frontend to one models.rs conflict, every validation round
  # reported it missing, and fix ghosts re-implemented it blind —
  # manufacturing exactly the duplicate definitions that killed the run.
  # Visible markers are strictly better than invisible absence.
  #
  # Returns {:ok, conflicted_files}.
  defp consolidate_impl_branches(mission, done_impl_ops) do
    # Target the CANONICAL worktree (chain tip; fix ops excluded from
    # selection — they adopt older shells and drag the target backward,
    # run 17's re-implementation spiral). The target branch is whatever
    # the canonical worktree currently has checked out — the deepest
    # point of the lineage including post-chain fix commits.
    with %{worktree_path: wt, ghost_id: target_ghost} <-
           GiTF.Validation.canonical_impl_shell(mission),
         true <- File.dir?(wt) do
      target_branch = GiTF.Validation.canonical_branch(mission) || "ghost/#{target_ghost}"

      # Validation/quality commands run in this same worktree between
      # rounds and leave tracked residue (lockfile rewrites, cache
      # touches). Merging over a dirty tree either sweeps the residue
      # into a merge commit or aborts with a false "local changes"
      # conflict — clear it first; all real work is already committed.
      case GiTF.Git.restore_tracked_residue(wt) do
        [] ->
          :ok

        residue ->
          Logger.info(
            "Quest #{mission.id}: reverted pre-consolidation residue: #{Enum.join(residue, ", ")}"
          )
      end

      conflicted =
        done_impl_ops
        |> Enum.map(& &1[:ghost_id])
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&("ghost/" <> &1))
        |> Enum.uniq()
        |> Enum.reject(&(&1 == target_branch))
        # Skip branches already contained in this tree. Consolidation runs
        # on EVERY validation round, and re-merging a branch whose commits
        # are already present re-injected the same conflict markers the fix
        # loop had just reconciled — run 32 burned its whole budget
        # resolving Settings.ts, then MainApp.tsx, then Settings.ts again.
        |> Enum.reject(&GiTF.Git.merged?(wt, &1))
        |> Enum.flat_map(fn branch ->
          case GiTF.Git.merge_union(wt, branch) do
            :ok ->
              Logger.info("Quest #{mission.id}: consolidated #{branch} into #{target_branch}")
              []

            {:conflicted, files} ->
              # Generated files are not worth reconciling: both sides are
              # machine output from the same source of truth, so the merge
              # is meaningless and the regenerator is authoritative. Run 32
              # burned rounds hand-merging src/bindings/Settings.ts, which
              # `npm run bindings` rewrites wholesale from the Rust structs.
              {generated, human} = Enum.split_with(files, &generated_file?/1)
              regenerated = if generated == [], do: [], else: regenerate(wt, generated)

              unresolved = human ++ (generated -- regenerated)

              if regenerated != [] do
                Logger.info(
                  "Quest #{mission.id}: regenerated #{Enum.join(regenerated, ", ")} " <>
                    "instead of merging machine output"
                )
              end

              if unresolved != [] do
                Logger.warning(
                  "Quest #{mission.id}: consolidation merge of #{branch} conflicted in " <>
                    "#{Enum.join(unresolved, ", ")} — committed WITH conflict markers so no " <>
                    "work is dropped; the fix loop must reconcile the marked regions"
                )
              end

              unresolved

            {:error, out} ->
              reason = out |> to_string() |> String.trim() |> String.slice(0, 200)

              Logger.warning(
                "Quest #{mission.id}: consolidation merge of #{branch} failed without " <>
                  "content conflicts (#{reason}) — branch NOT merged; surfacing to validation"
              )

              # A dropped branch must be as visible as a conflicted file:
              # run 21's final fix branch aborted here with an empty reason
              # and validation judged a tree silently missing that work.
              # This synthetic entry rides the merge_conflicts list into the
              # validation prompt so the fix loop knows work is absent.
              [
                "UNMERGED BRANCH #{branch} (merge failed: #{reason}) — its commits are " <>
                  "missing from this tree; merge it or re-apply its work"
              ]
          end
        end)
        |> Enum.uniq()

      {:ok, conflicted}
    else
      _ -> {:ok, []}
    end
  rescue
    e ->
      Logger.warning(
        "consolidate_impl_branches crashed for #{mission.id}: #{Exception.message(e)}"
      )

      {:ok, []}
  end

  # The branch a mission is amending, when it is amending one. Callers use it
  # as the base for worktrees so ghosts see the code under review.
  defp mission_base_branch_opts(mission) do
    case Map.get(mission, :target_branch) do
      branch when is_binary(branch) and branch != "" -> [base_branch: branch]
      _ -> []
    end
  end

  defp impl_base_branch_opts(mission) do
    # Base validation on the canonical worktree's CURRENT branch — the
    # deepest lineage point, including post-chain fix commits. An
    # op-derived branch name can lag (run 17: validation based on chain
    # op 2's branch while ops 3-4 and fixes lived further down the line).
    case GiTF.Validation.canonical_branch(mission) do
      branch when is_binary(branch) ->
        [base_branch: branch]

      _ ->
        case GiTF.Validation.latest_completed_impl_op(mission) do
          %{ghost_id: ghost_id} when is_binary(ghost_id) ->
            [base_branch: "ghost/#{ghost_id}"]

          # No prior impl work: fall back to the branch being amended, if
          # any, rather than sector HEAD.
          _ ->
            mission_base_branch_opts(mission)
        end
    end
  end

  defp check_design_complete(mission) do
    design_ops =
      Archive.filter(:ops, fn j ->
        j.mission_id == mission.id and
          j[:phase_job] == true and
          j[:phase] == "design"
      end)

    if design_ops == [] do
      {:ok, "design"}
    else
      done_ops = Enum.filter(design_ops, &(&1.status == "done"))
      failed_ops = Enum.filter(design_ops, &(&1.status == "failed"))
      total = length(design_ops)
      terminal = length(done_ops) + length(failed_ops)

      if terminal == total do
        # All design ghosts finished — advance to review with all designs
        if done_ops == [] do
          Logger.warning("Quest #{mission.id}: all design ghosts failed")
          fail_quest(mission.id, "All design strategies failed")
        else
          {:ok, mission} = GiTF.Missions.get(mission.id)

          # Review exists to cross-validate multiple design proposals; a
          # single-variant design has nothing to pick among.
          done_variants = Enum.map(done_ops, &op_strategy/1) |> Enum.uniq()

          if length(done_variants) <= 1 do
            selected = List.first(done_variants) || "minimal"
            promote_selected_design(mission.id, %{"selected_design" => selected})
            {:ok, mission} = GiTF.Missions.get(mission.id)
            start_planning(mission)
          else
            start_review(mission)
          end
        end
      else
        {:ok, "design"}
      end
    end
  end

  # Reads the op's stored strategy; falls back to a title parse for records
  # written before the `strategy` field existed, and finally to "normal" for
  # ops that have no strategy concept. Prefer `op[:strategy]` for new writes
  # via `spawn_phase_ghost_inner`.
  @doc false
  def op_strategy(op) do
    case op[:strategy] do
      s when is_binary(s) and s != "" ->
        s

      _ ->
        case Regex.run(~r/\[([^\]]+)\]/, op.title || "") do
          [_, strategy] -> strategy
          _ -> "normal"
        end
    end
  end

  # -- Phase Transition Logic --------------------------------------------------

  @default_phase_timeout_seconds 900

  defp check_and_advance(mission, phase, next_fn) do
    artifact = GiTF.Missions.get_artifact(mission.id, phase)

    if artifact && !artifact_failed?(artifact) do
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
        timeout = phase_timeout_for(mission.sector_id, phase)

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

            case rebuild_phase_prompt(mission, phase) do
              {prompt, model} ->
                spawn_phase_ghost(mission, phase, prompt, model: model)

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

  defp check_research_and_advance(mission) do
    artifact = GiTF.Missions.get_artifact(mission.id, "research")

    if artifact && !artifact_failed?(artifact) do
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
        start_requirements(mission)
      else
        Logger.info(
          "Quest #{mission.id}: Research identified high complexity, continuing deep plan"
        )

        start_requirements(mission)
      end
    else
      Logger.warning(
        "Quest #{mission.id}: research artifact not found, falling back to check_and_advance"
      )

      check_and_advance(mission, "research", &start_requirements/1)
    end
  end

  # Rebuild the real prompt for a phase re-spawn using available artifacts
  defp rebuild_phase_prompt(mission, phase) do
    sector = if mission.sector_id, do: Archive.get(:sectors, mission.sector_id)
    ctx = GiTF.Intel.get_prompt_context(mission.sector_id, phase, mission)

    case phase do
      "research" ->
        {PhasePrompts.research_prompt(mission, sector, ctx,
           complexity: triage_complexity(mission)
         ), "general"}

      "triage" ->
        {PhasePrompts.triage_prompt(mission, sector), "general"}

      "requirements" ->
        research = GiTF.Missions.get_artifact(mission.id, "research") || %{}
        {PhasePrompts.requirements_prompt(mission, research, ctx), "general"}

      "design" ->
        requirements = GiTF.Missions.get_artifact(mission.id, "requirements") || %{}
        research = GiTF.Missions.get_artifact(mission.id, "research") || %{}
        {PhasePrompts.design_prompt(mission, requirements, research, "", ctx), "thinking"}

      "review" ->
        design = GiTF.Missions.get_artifact(mission.id, "design") || %{}
        requirements = GiTF.Missions.get_artifact(mission.id, "requirements") || %{}
        research = GiTF.Missions.get_artifact(mission.id, "research") || %{}
        {PhasePrompts.review_prompt(mission, design, requirements, research), "thinking"}

      "planning" ->
        design = GiTF.Missions.get_artifact(mission.id, "design") || %{}
        requirements = GiTF.Missions.get_artifact(mission.id, "requirements") || %{}
        review = GiTF.Missions.get_artifact(mission.id, "review") || %{}
        {PhasePrompts.planning_prompt(mission, design, requirements, review, ctx), "thinking"}

      "validation" ->
        requirements = GiTF.Missions.get_artifact(mission.id, "requirements") || %{}
        planning = GiTF.Missions.get_artifact(mission.id, "planning") || %{}

        prompt =
          PhasePrompts.validation_prompt(mission, requirements, planning, ctx,
            diff_base: detect_diff_base(mission),
            changed_files: GiTF.Validation.mission_changed_files(mission, completed_only: true)
          )

        {prompt, "general"}

      phase when phase in ["implementation", "sync", "awaiting_approval"] ->
        # These phases don't use phase ghosts — handled by op spawning,
        # sync queue, or user approval respectively. No prompt rebuild needed.
        nil

      _ ->
        {"Re-attempt #{phase} phase", "general"}
    end
  rescue
    e ->
      Logger.warning("Failed to rebuild prompt for phase #{phase}: #{Exception.message(e)}")
      {"Re-attempt #{phase} phase (prompt rebuild failed)", "general"}
  end

  defp handle_review_result(mission) do
    review = GiTF.Missions.get_artifact(mission.id, "review")

    cond do
      is_nil(review) ->
        {:ok, "review"}

      review["approved"] == true ->
        # Copy the selected design variant to the canonical "design" key
        promote_selected_design(mission.id, review)
        {:ok, mission} = GiTF.Missions.get(mission.id)
        start_planning(mission)

      true ->
        redesign_count = Map.get(mission, :redesign_count, 0)

        if redesign_count < max_redesign_for(mission.sector_id) do
          Archive.update(:missions, mission.id, fn q ->
            Map.update(q, :redesign_count, 1, &(&1 + 1))
          end)

          {:ok, mission} = GiTF.Missions.get(mission.id)
          start_design(mission)
        else
          Logger.warning(
            "Quest #{mission.id} exceeded max redesign iterations, proceeding with current design"
          )

          promote_selected_design(mission.id, review)
          {:ok, mission} = GiTF.Missions.get(mission.id)
          start_planning(mission)
        end
    end
  end

  @doc """
  Copies the review-selected design variant onto the canonical
  `"design"` artifact key. Public so `GiTF.Phases.Review` can call it
  without duplicating the strategy-fallback logic.
  """
  @spec promote_selected_design(String.t(), map()) :: :ok | {:error, term()}
  def promote_selected_design(mission_id, review) do
    selected = review["selected_design"] || "normal"
    key = "design_#{selected}"

    case GiTF.Missions.get_artifact(mission_id, key) do
      nil ->
        # Fallback: try other variants or existing "design" artifact
        fallback =
          Enum.find_value(@design_strategies, fn %{name: name} ->
            GiTF.Missions.get_artifact(mission_id, "design_#{name}")
          end)

        if fallback, do: GiTF.Missions.store_artifact(mission_id, "design", fallback)

      design ->
        GiTF.Missions.store_artifact(mission_id, "design", design)
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
          start_validation(mission)
        else
          complete_quest(mission.id)
        end

      Enum.all?(impl_jobs, &(&1.status == "done")) ->
        # Only start validation if this is a new-style mission with sector_id
        if Map.get(mission, :sector_id) do
          {:ok, mission} = GiTF.Missions.get(mission.id)
          start_validation(mission)
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
              start_validation(mission)
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
      start_validation(mission)
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

  # -- Simplify Phase: 3 parallel agents (reuse, quality, efficiency) ----------

  defp start_simplify(mission) do
    if Decisions.simplify_skippable?(triage_complexity(mission)) do
      Logger.info(
        "Quest #{mission.id}: skipping simplify (triage complexity is low) — going straight to scoring"
      )

      with {:ok, _} <-
             GiTF.Missions.transition_phase(mission.id, "simplify", "Skipped (low complexity)") do
        GiTF.Missions.store_artifact(mission.id, "simplify", %{
          "agents" => [],
          "skipped" => true,
          "skipped_reason" => "triage_complexity_low",
          "completed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

        {:ok, mission} = GiTF.Missions.get(mission.id)
        GiTF.Publish.start(mission)
      end
    else
      with {:ok, _} <-
             GiTF.Missions.transition_phase(mission.id, "simplify", "Sync complete, simplifying") do
        sector = Archive.get(:sectors, mission.sector_id)
        repo_path = if sector, do: sector.path, else: nil

        # Get changed files from all implementation ops
        changed_files = GiTF.Validation.mission_changed_files(mission)

        # Branch simplify worktrees from the quest branch (the one sync just
        # merged impl ghosts into) so cleanup commits land on that branch
        # and get picked up by publish's push/PR. Without this, worktrees
        # branch from sector HEAD and simplify commits are orphaned.
        opts = [model: "general"] ++ quest_branch_base_opts(mission)

        for {focus, prompt} <- PhasePrompts.simplify_prompts(mission, repo_path, changed_files) do
          spawn_phase_ghost(mission, "simplify", prompt, opts ++ [strategy: focus])
        end

        {:ok, "simplify"}
      end
    end
  end

  # Returns [base_branch: <quest-branch>] when sync recorded a branch for
  # the mission, or [] if not available. Used by simplify so its cleanup
  # commits land on the quest branch instead of orphaning from main.
  defp quest_branch_base_opts(mission) do
    case GiTF.Missions.get_artifact(mission.id, "sync") do
      %{"branch" => branch} when is_binary(branch) and branch != "" ->
        [base_branch: branch]

      _ ->
        []
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
            strategy = op_strategy(op)
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

  @doc false
  # -- Scoring Phase: final quality assessment --------------------------------

  defp start_scoring(mission) do
    with {:ok, _} <-
           GiTF.Missions.transition_phase(mission.id, "scoring", "Simplify complete, scoring") do
      requirements = GiTF.Missions.get_artifact(mission.id, "requirements")
      validation = GiTF.Missions.get_artifact(mission.id, "validation")
      ctx = GiTF.Intel.get_prompt_context(mission.sector_id, "scoring", mission)
      prompt = PhasePrompts.scoring_prompt(mission, requirements, validation, ctx)
      spawn_phase_ghost(mission, "scoring", prompt, model: "general")
      {:ok, "scoring"}
    end
  end

  # Store triage-vs-outcome data for future accuracy analysis.
  # Links the original triage complexity to the final quality score so
  # patterns like "ops triaged as simple but scored < 70" can be detected.
  defp ingest_failure_outcome(mission_id) do
    Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
      case GiTF.Missions.get(mission_id) do
        {:ok, mission} ->
          mission.ops
          |> Enum.filter(&(&1.status == "failed"))
          |> Enum.each(fn op ->
            try do
              GiTF.Intel.FailureAnalysis.analyze_failure(op.id)
            rescue
              e ->
                Logger.warning(
                  "ingest_failure_outcome: per-op analysis failed for #{op.id}: " <>
                    Exception.message(e)
                )

                :ok
            end
          end)

          GiTF.Intel.SectorProfile.invalidate(mission.sector_id)

        _ ->
          :ok
      end
    end)
  rescue
    _ -> :ok
  end

  defp fail_quest(mission_id, reason) do
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
    ingest_failure_outcome(mission_id)

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
      failure_type: classify_reason(reason),
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

  @failure_patterns [
    {~r/timed?\s*out|timeout|exceeded.*h\b/i, :timeout},
    {~r/budget|cost|spend/i, :budget_exceeded},
    {~r/compil|syntax|undefined function/i, :compilation_error},
    {~r/test.*fail|assertion|assert/i, :test_failure},
    {~r/context.*overflow|context.*handoff|context.*limit/i, :context_overflow},
    {~r/validation.*fail|validator|verdict.*fail/i, :validation_failure},
    {~r/quality.*gate|quality.*below|score.*below/i, :quality_gate_failure},
    {~r/security|vulnerab|secret/i, :security_gate_failure},
    {~r/merge.*conflict|conflict.*in/i, :merge_conflict},
    {~r/provider.*unavail|all.*providers.*down|circuit.*open/i, :provider_unavailable},
    {~r/rejected|human.*review.*rejected/i, :review_rejected},
    {~r/no sector|auto.assign.*fail/i, :configuration_error}
  ]

  defp classify_reason(reason) when is_binary(reason) do
    Enum.find_value(@failure_patterns, :unknown, fn {pattern, type} ->
      if Regex.match?(pattern, reason), do: type
    end)
  end

  defp classify_reason(_), do: :unknown

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
          maybe_delete_mission_branch(mission_id, sector)
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

  # Deletes the mission branch ONLY when sync strategy is auto_merge (the
  # branch has been merged into main and has no open PR pointing at it).
  # For pr_branch strategy, the branch must stay until the PR is
  # merged/closed — deleting it would orphan or close the PR.
  defp maybe_delete_mission_branch(mission_id, sector) do
    strategy = Map.get(sector, :sync_strategy) || "auto_merge"

    with true <- strategy == "auto_merge",
         sync_art when is_map(sync_art) <- GiTF.Missions.get_artifact(mission_id, "sync"),
         branch when is_binary(branch) <- sync_art["branch"] do
      GiTF.Git.branch_delete(sector.path, branch)

      GiTF.Git.safe_cmd(["push", "origin", "--delete", branch],
        cd: sector.path,
        stderr_to_stdout: true
      )

      Logger.info("Cleaned up mission branch #{branch} (auto_merge completed)")
    else
      _ -> :ok
    end
  end

  # -- Ghost Spawning ----------------------------------------------------------

  defp spawn_phase_ghost(mission, phase, prompt, opts) do
    strategy = Keyword.get(opts, :strategy)

    # Guard: don't create duplicate phase ops (prevents retry loops from spawning 100+ ops)
    existing =
      Enum.find(mission.ops, fn op ->
        op[:phase_job] && op[:phase] == phase &&
          op.status in ["pending", "running", "assigned"] &&
          (is_nil(strategy) || String.contains?(op.title || "", "[#{strategy}]"))
      end)

    if existing do
      Logger.debug(
        "Phase op already exists for #{phase}#{if strategy, do: " [#{strategy}]"}, skipping duplicate"
      )

      {:ok, nil}
    else
      spawn_phase_ghost_inner(mission, phase, prompt, opts)
    end
  end

  defp spawn_phase_ghost_inner(mission, phase, prompt, opts) do
    default_model = Keyword.get(opts, :model, "general")
    model = pick_model_for_phase(mission.sector_id, phase, default_model)

    GiTF.Telemetry.start_phase_span(phase, mission.id)

    GiTF.Telemetry.emit(
      [:gitf, :phase, :prompt_built],
      %{prompt_bytes: byte_size(prompt)},
      %{phase: phase, mission_id: mission.id, model: model}
    )

    strategy = Keyword.get(opts, :strategy)
    variant = Keyword.get(opts, :variant)

    # Build title with strategy or variant label for parallel ghosts.
    title =
      cond do
        variant ->
          "#{String.capitalize(phase)} [#{variant}] for: #{String.slice(mission.goal, 0, 50)}"

        strategy ->
          "#{String.capitalize(phase)} [#{strategy}] for: #{String.slice(mission.goal, 0, 50)}"

        true ->
          "#{String.capitalize(phase)} phase for: #{String.slice(mission.goal, 0, 60)}"
      end

    # Create a phase op
    job_attrs = %{
      title: title,
      description: prompt,
      mission_id: mission.id,
      sector_id: mission.sector_id,
      phase_job: true,
      phase: phase,
      strategy: strategy,
      variant: variant,
      assigned_model: model_id(model)
    }

    # A mission amending an open pull request must WORK ON that branch, not
    # merely merge into it later. target_branch was applied only in
    # Sync.merge_quest, so every ghost was cut from main: on msn-dd29a1 the
    # file under review did not exist in any ghost's worktree, the correct
    # commit fell out of a union merge rather than a ghost editing it, and
    # validation then diffed a tree without the change and reported the work
    # missing. Defaulting here covers every phase in one place.
    spawn_opts =
      [prompt: prompt]
      |> Keyword.merge(mission_base_branch_opts(mission))
      |> Keyword.merge(Keyword.take(opts, [:base_branch]))

    with {:ok, op} <- GiTF.Ops.create(job_attrs),
         _ = GiTF.Missions.record_phase_job(mission.id, phase, op.id),
         {:ok, gitf_root} <- GiTF.gitf_dir(),
         {:ok, ghost} <-
           GiTF.Ghosts.spawn_detached(op.id, mission.sector_id, gitf_root, spawn_opts) do
      Logger.info("Phase ghost #{ghost.id} spawned for #{phase} phase of mission #{mission.id}")

      {:ok, ghost}
    else
      {:error, reason} ->
        error_reason = if reason == :no_gitf_root, do: "no_gitf_root", else: inspect(reason)

        Logger.error("Failed to spawn #{phase} phase ghost: #{error_reason}")

        GiTF.Telemetry.emit([:gitf, :phase, :spawn_failed], %{}, %{
          mission_id: mission.id,
          phase: phase,
          reason: error_reason
        })

        {:error, reason}
    end
  end

  @doc """
  Max redesign iterations for `sector_id`, consulting sector
  intelligence at `:high` confidence. Public so `GiTF.Phases.Review`
  can apply the same policy.
  """
  @spec max_redesign_for(String.t() | nil) :: pos_integer()
  def max_redesign_for(nil), do: @default_max_redesign

  def max_redesign_for(sector_id) do
    profile = GiTF.Intel.SectorProfile.get_or_compute(sector_id)

    case profile do
      %{confidence: :high, recommendations: %{max_redesign_iterations: n}} -> n
      _ -> @default_max_redesign
    end
  rescue
    _ -> @default_max_redesign
  end

  # Returns the phase timeout in seconds, consulting sector intelligence.
  defp phase_timeout_for(nil, _phase), do: @default_phase_timeout_seconds

  defp phase_timeout_for(sector_id, phase) do
    profile = GiTF.Intel.SectorProfile.get_or_compute(sector_id)

    case profile do
      %{confidence: conf, lessons: %{avg_phase_durations: durations}}
      when conf in [:medium, :high] and map_size(durations) > 0 ->
        avg = Map.get(durations, phase, 600)
        computed = round(avg * 1.5) |> max(300) |> min(1800)
        GiTF.Intel.SectorProfile.blend(computed, @default_phase_timeout_seconds, conf)

      _ ->
        @default_phase_timeout_seconds
    end
  rescue
    _ -> @default_phase_timeout_seconds
  end

  # Consults sector intelligence to pick the best model for a phase.
  # At low confidence, returns the default. At medium, only overrides if the
  # default model is declining. At high, uses the best available model.
  defp pick_model_for_phase(nil, _phase, default_model), do: default_model

  defp pick_model_for_phase(sector_id, _phase, default_model) do
    profile = GiTF.Intel.SectorProfile.get_or_compute(sector_id)

    case profile do
      %{confidence: :high, recommendations: %{default_model: rec_model}}
      when is_binary(rec_model) and rec_model != "" ->
        rec_model

      %{confidence: :medium, model_data: model_data} ->
        # At medium confidence, only swap away from a declining model
        default_key = normalize_model_key(default_model)

        case Map.get(model_data, default_key) do
          %{trend: :declining} ->
            # Find a non-declining alternative
            find_non_declining_model(model_data, default_model)

          _ ->
            default_model
        end

      _ ->
        default_model
    end
  rescue
    _ -> default_model
  end

  defp find_non_declining_model(model_data, fallback) do
    model_data
    |> Enum.reject(fn {_model, data} -> data.trend == :declining end)
    |> Enum.filter(fn {_model, data} -> data.total_jobs >= 3 end)
    |> Enum.max_by(fn {_model, data} -> data.success_rate end, fn -> nil end)
    |> case do
      {model, _} -> model
      nil -> fallback
    end
  end

  defp normalize_model_key(model), do: GiTF.Runtime.ModelResolver.normalize_key(model)

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

  defp generate_synthetic_jobs(mission) do
    # Try to derive tasks from requirements artifact
    requirements = GiTF.Missions.get_artifact(mission.id, "requirements")
    design = GiTF.Missions.get_artifact(mission.id, "design")

    specs =
      cond do
        is_map(requirements) and is_list(requirements["functional_requirements"]) ->
          requirements["functional_requirements"]
          |> Enum.with_index(1)
          |> Enum.map(fn {req, idx} ->
            %{
              "title" =>
                "Implement requirement #{idx}: #{String.slice(to_string(req["name"] || req), 0, 60)}",
              "description" => to_string(req["description"] || req),
              "op_type" => "implementation"
            }
          end)

        is_map(design) and is_list(design["components"]) ->
          design["components"]
          |> Enum.map(fn comp ->
            %{
              "title" =>
                "Implement component: #{String.slice(to_string(comp["name"] || comp), 0, 60)}",
              "description" => to_string(comp["description"] || Jason.encode!(comp)),
              "op_type" => "implementation"
            }
          end)

        true ->
          # Last resort: single op from mission goal. For triage-direct-to-
          # impl paths (trivial/simple complexity, all pre-phases skipped),
          # propagate triage's target_files + goal_restatement + external
          # context into the op so the impl ghost has navigation scaffolding.
          triage = GiTF.Missions.get_artifact(mission.id, "triage") || %{}

          [
            %{
              "title" => "Implement: #{String.slice(mission.goal, 0, 80)}",
              "description" => synthetic_impl_description(mission, triage),
              "target_files" => Map.get(triage, "target_files") || [],
              "op_type" => "implementation"
            }
          ]
      end

    if specs != [] do
      Logger.info("Quest #{mission.id}: generated #{length(specs)} synthetic ops from artifacts")
      # Route through `create_implementation_ops/2` so the synthetic
      # fallback honours `Tournament.configured_attempts/0` the same way
      # the planning-artifact path does — otherwise triage-skip-planning
      # missions silently bypass the tournament feature.
      create_implementation_ops(mission, specs)
    end

    {:ok, specs}
  rescue
    e ->
      Logger.warning(
        "Synthetic op generation failed for mission #{mission.id}: #{Exception.message(e)}"
      )

      {:ok, []}
  end

  # Builds an impl op's description by folding in whatever triage already
  # figured out. Without this, a trivial-triaged impl ghost gets only the
  # raw mission goal and has to search the repo blindly — which fast models
  # like gemini-2.5-flash handle poorly (they loop on Read/Grep).
  defp synthetic_impl_description(mission, triage) do
    sections = [
      mission.goal,
      case Map.get(triage, "goal_restatement") do
        nil -> nil
        "" -> nil
        txt -> "\n\n## Triage restatement\n#{txt}"
      end,
      case Map.get(triage, "target_files") do
        [_ | _] = files ->
          "\n\n## Target files (identified by triage)\n" <>
            Enum.map_join(files, "\n", &"- #{&1}")

        _ ->
          nil
      end,
      case Map.get(triage, "external_context") do
        nil -> nil
        "" -> nil
        txt -> "\n\n## External context\n#{txt}"
      end
    ]

    sections |> Enum.reject(&is_nil/1) |> Enum.join("")
  end

  defp is_client_facing?(mission) do
    text = String.downcase(mission.goal)

    Enum.any?(
      ["ui", "client", "frontend", "web", "user interface", "ux", "dashboard", "app"],
      &String.contains?(text, &1)
    )
  end

  # -- Helpers -----------------------------------------------------------------

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

  defp validate_design_phase(mission) do
    if Map.get(mission, :current_phase) in ["design", "review"] do
      :ok
    else
      {:error, :not_in_design_phase}
    end
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

  defp max_quest_age_hours, do: Config.get([:major, :mission_timeout_hours], 24)

  defp model_id(tier) do
    GiTF.Runtime.ModelResolver.resolve(tier)
  end

  defp summarize_artifacts(artifacts) when map_size(artifacts) == 0, do: %{}

  defp summarize_artifacts(artifacts) do
    Map.new(artifacts, fn {phase, artifact} ->
      summary =
        case phase do
          "research" ->
            key_files = Map.get(artifact, "key_files", [])
            "#{length(key_files)} key files identified"

          "requirements" ->
            reqs = Map.get(artifact, "functional_requirements", [])
            "#{length(reqs)} functional requirements"

          "design" ->
            components = Map.get(artifact, "components", [])
            "#{length(components)} components designed"

          "review" ->
            approved = Map.get(artifact, "approved", false)
            if approved, do: "Approved", else: "Rejected"

          "planning" when is_list(artifact) ->
            "#{length(artifact)} ops planned"

          "validation" ->
            Map.get(artifact, "overall_verdict", "unknown")

          _ ->
            "completed"
        end

      {phase, summary}
    end)
  end

  # Returns true if the artifact was a fallback from a failed parse (empty ghost output).
  defp artifact_failed?(artifact) when is_map(artifact) do
    # A compacted stub is not a usable artifact: treating it as one made
    # resumed missions read nil complexity -> :complex -> full pipeline
    # re-run on phases they'd already paid for.
    Map.get(artifact, "parse_failed", false) == true or
      Map.get(artifact, "compacted", false) == true
  end

  defp artifact_failed?(_), do: false
end
