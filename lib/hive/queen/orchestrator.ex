defmodule Hive.Queen.Orchestrator do
  @moduledoc """
  Queen's orchestration capabilities for the expert-driven pipeline.

  Manages the full phase pipeline:
  pending → research → requirements → design → review → planning → implementation → validation → completed

  Each phase spawns a bee that produces a structured JSON artifact stored
  on the quest record. When a phase bee's "job_complete" waggle arrives,
  the Queen calls `advance_quest`, which checks for the artifact and
  spawns the next phase's bee.
  """

  require Logger

  alias Hive.Store
  alias Hive.Queen.{FastPath, PhasePrompts, Planner}

  @phases ~w(research requirements design review planning implementation validation awaiting_approval merge)
  @max_redesign_iterations 2
  @approval_timeout_hours 1
  @max_quest_age_hours 24

  # -- Public API --------------------------------------------------------------

  @doc """
  Start a quest workflow.

  Validates the quest is ready and kicks off the research phase.
  """
  @spec start_quest(String.t()) :: {:ok, map()} | {:error, term()}
  def start_quest(quest_id) do
    with {:ok, quest} <- Hive.Quests.get(quest_id),
         :ok <- validate_quest_ready(quest) do
      # Fast path: skip all phases for trivial quests
      if FastPath.eligible?(quest) do
        Logger.info("Quest #{quest_id} eligible for fast path, skipping phase pipeline")
        FastPath.execute(quest_id)
      else
        # If a confirmed plan (planning artifact) already exists, skip to implementation
        planning_artifact = Hive.Quests.get_artifact(quest_id, "planning")

        if planning_artifact && is_list(planning_artifact) && planning_artifact != [] do
          Logger.info("Quest #{quest_id} has pre-confirmed plan, skipping to implementation")
          start_implementation(quest)
        else
          start_research(quest)
        end
      end
    end
  end

  @doc """
  Get quest status with phase information.
  """
  @spec get_quest_status(String.t()) :: {:ok, map()} | {:error, term()}
  def get_quest_status(quest_id) do
    with {:ok, quest} <- Hive.Quests.get(quest_id) do
      transitions = Hive.Quests.get_phase_transitions(quest_id)
      artifacts = Map.get(quest, :artifacts, %{})

      status = %{
        quest: quest,
        current_phase: Map.get(quest, :current_phase, "pending"),
        phase_history: transitions,
        completed_phases: Map.keys(artifacts),
        artifacts_summary: summarize_artifacts(artifacts),
        jobs_created: length(quest.jobs) > 0
      }

      {:ok, status}
    end
  end

  @doc """
  Advance quest to next phase if current phase is complete.

  Called by the Queen when a bee completes. Checks if the current phase's
  artifact exists, and if so, transitions to the next phase.
  """
  @spec advance_quest(String.t()) :: {:ok, String.t()} | {:error, term()}
  def advance_quest(quest_id) do
    with {:ok, quest} <- Hive.Quests.get(quest_id) do
      # Circuit breaker: fail quests that have been running too long
      if quest_timed_out?(quest) do
        Logger.warning("Quest #{quest_id} exceeded #{@max_quest_age_hours}h max age, force-completing")
        Hive.Quests.transition_phase(quest_id, "completed",
          "Quest timed out after #{@max_quest_age_hours}h")
        Hive.Quests.update_status!(quest_id)

        Hive.Telemetry.emit([:hive, :alert, :raised], %{}, %{
          type: :quest_timeout,
          message: "Quest #{quest_id} force-completed after #{@max_quest_age_hours}h timeout"
        })

        {:ok, "completed"}
      else
        advance_quest_phase(quest)
      end
    end
  end

  defp quest_timed_out?(quest) do
    case quest[:inserted_at] do
      %DateTime{} = started ->
        hours = DateTime.diff(DateTime.utc_now(), started, :second) / 3600
        phase = Map.get(quest, :current_phase, "pending")
        # Don't timeout quests that are completed or awaiting approval
        phase not in ["completed", "awaiting_approval", "pending"] and
          hours > @max_quest_age_hours

      _ ->
        false
    end
  end

  defp advance_quest_phase(quest) do
      phase = Map.get(quest, :current_phase, "pending")

      case phase do
        "pending" ->
          # Only start research if quest has a comb_id (new-style quests)
          if Map.get(quest, :comb_id) do
            start_research(quest)
          else
            {:ok, phase}
          end

        "research" ->
          check_and_advance(quest, "research", &start_requirements/1)

        "requirements" ->
          check_and_advance(quest, "requirements", &start_design/1)

        "design" ->
          check_and_advance(quest, "design", &start_review/1)

        "review" ->
          handle_review_result(quest)

        "planning" ->
          check_and_advance(quest, "planning", &start_implementation/1)

        "implementation" ->
          check_implementation_complete(quest)

        "validation" ->
          handle_validation_result(quest)

        "awaiting_approval" ->
          handle_approval_result(quest)

        other ->
          {:ok, other}
      end
  end

  @doc """
  Returns the ordered list of pipeline phases.
  """
  @spec phases() :: [String.t()]
  def phases, do: @phases

  # -- Phase Starters ----------------------------------------------------------

  defp start_research(quest) do
    comb_id = Map.get(quest, :comb_id)

    if is_nil(comb_id) do
      {:error, :no_comb_assigned}
    else
      with {:ok, _} <- Hive.Quests.transition_phase(quest.id, "research", "Quest started") do
        comb = Store.get(:combs, comb_id)
        prompt = PhasePrompts.research_prompt(quest, comb)
        spawn_phase_bee(quest, "research", prompt, model: "sonnet")
        {:ok, "research"}
      end
    end
  end

  defp start_requirements(quest) do
    research = Hive.Quests.get_artifact(quest.id, "research")

    with {:ok, _} <- Hive.Quests.transition_phase(quest.id, "requirements", "Research complete") do
      prompt = PhasePrompts.requirements_prompt(quest, research)
      spawn_phase_bee(quest, "requirements", prompt, model: "sonnet")
      {:ok, "requirements"}
    end
  end

  defp start_design(quest) do
    requirements = Hive.Quests.get_artifact(quest.id, "requirements")
    research = Hive.Quests.get_artifact(quest.id, "research")

    with {:ok, _} <- Hive.Quests.transition_phase(quest.id, "design", "Requirements complete") do
      # Check if this is a redesign iteration with review feedback
      review = Hive.Quests.get_artifact(quest.id, "review")

      extra_instructions =
        if is_client_facing?(quest) do
          "6. ACT AS A BEHAVIORAL SCIENTIST: This is a client-facing project. Evaluate the plan for how people might think about it and what would make it exceptionally useful. Incorporate behavioral insights into the component design."
        else
          ""
        end

      prompt =
        if review && review["approved"] == false do
          PhasePrompts.design_prompt_with_feedback(quest, requirements, research, review, extra_instructions)
        else
          PhasePrompts.design_prompt(quest, requirements, research, extra_instructions)
        end

      spawn_phase_bee(quest, "design", prompt, model: "opus")

      {:ok, "design"}
    end
  end

  defp start_review(quest) do
    design = Hive.Quests.get_artifact(quest.id, "design")
    requirements = Hive.Quests.get_artifact(quest.id, "requirements")
    research = Hive.Quests.get_artifact(quest.id, "research")

    with {:ok, _} <- Hive.Quests.transition_phase(quest.id, "review", "Design complete") do
      prompt = PhasePrompts.review_prompt(quest, design, requirements, research)
      spawn_phase_bee(quest, "review", prompt, model: "opus")
      {:ok, "review"}
    end
  end

  defp start_planning(quest) do
    design = Hive.Quests.get_artifact(quest.id, "design")
    requirements = Hive.Quests.get_artifact(quest.id, "requirements")
    review = Hive.Quests.get_artifact(quest.id, "review")

    with {:ok, _} <- Hive.Quests.transition_phase(quest.id, "planning", "Review approved") do
      prompt = PhasePrompts.planning_prompt(quest, design, requirements, review)
      spawn_phase_bee(quest, "planning", prompt, model: "sonnet")
      {:ok, "planning"}
    end
  end

  defp start_implementation(quest) do
    planning_artifact = Hive.Quests.get_artifact(quest.id, "planning")

    with {:ok, _} <- Hive.Quests.transition_phase(quest.id, "implementation", "Planning complete") do
      # Try multi-plan generation to produce 3 scored alternatives
      # Falls back to raw planning artifact on failure
      case planning_artifact do
        specs when is_list(specs) and specs != [] ->
          case Planner.generate_candidate_plans(quest.id) do
            {:ok, best_plan} ->
              best_tasks = best_plan[:tasks] || best_plan.tasks || []

              if is_list(best_tasks) and best_tasks != [] do
                Logger.info("Quest #{quest.id}: using multi-plan best candidate (#{best_plan[:strategy]})")
                Planner.create_jobs_from_specs(quest.id, best_tasks)
              else
                Logger.info("Quest #{quest.id}: multi-plan returned empty tasks, using planning artifact")
                Planner.create_jobs_from_specs(quest.id, specs)
              end

            {:error, reason} ->
              Logger.info("Quest #{quest.id}: multi-plan failed (#{inspect(reason)}), using planning artifact")
              Planner.create_jobs_from_specs(quest.id, specs)
          end

        _ ->
          Logger.warning("Planning artifact is not a list, falling back to synthetic planning")
          generate_synthetic_jobs(quest)
      end

      # Spawn ready jobs — the Queen's spawn_ready_jobs handles this
      {:ok, quest} = Hive.Quests.get(quest.id)
      spawn_implementation_jobs(quest)

      Hive.Quests.update_status!(quest.id)
      {:ok, "implementation"}
    end
  end

  defp start_validation(quest) do
    all_artifacts = Map.get(quest, :artifacts, %{})

    with {:ok, _} <- Hive.Quests.transition_phase(quest.id, "validation", "Implementation complete") do
      prompt = PhasePrompts.validation_prompt(quest, all_artifacts)
      spawn_phase_bee(quest, "validation", prompt, model: "sonnet")
      {:ok, "validation"}
    end
  end

  defp start_merge(quest) do
    with {:ok, _} <- Hive.Quests.transition_phase(quest.id, "merge", "Validation passed, merging") do
      case Hive.Merge.merge_quest(quest.id) do
        {:ok, branch} ->
          Hive.Quests.store_artifact(quest.id, "merge", %{
            "status" => "success",
            "branch" => branch,
            "merged_at" => DateTime.utc_now()
          })
          complete_quest(quest.id)

        {:error, reason} ->
          Hive.Quests.store_artifact(quest.id, "merge", %{
            "status" => "failed",
            "error" => inspect(reason)
          })
          Logger.warning("Quest #{quest.id} merge failed: #{inspect(reason)}, completing as failed")
          Hive.Quests.transition_phase(quest.id, "completed", "Merge failed: #{inspect(reason)}")
          Hive.Quests.update_status!(quest.id)
          {:ok, "completed"}
      end
    end
  end

  defp start_awaiting_approval(quest) do
    with {:ok, _} <- Hive.Quests.transition_phase(quest.id, "awaiting_approval", "Validation passed, awaiting human approval") do
      Hive.HumanGate.request_approval(quest.id)
      {:ok, "awaiting_approval"}
    end
  end

  defp handle_approval_result(quest) do
    case Hive.HumanGate.approval_status(quest.id) do
      :approved ->
        {:ok, quest} = Hive.Quests.get(quest.id)
        start_merge(quest)

      :rejected ->
        Logger.warning("Quest #{quest.id} rejected by human reviewer")
        Hive.Quests.transition_phase(quest.id, "completed", "Human review rejected")
        Hive.Quests.update_status!(quest.id)
        {:ok, "completed"}

      :pending ->
        # Check for approval timeout — re-validate then auto-approve
        if approval_timed_out?(quest.id) do
          # Re-validate before auto-approving to catch regressions
          validation_fresh? = revalidate_quest(quest)

          if validation_fresh? do
            Logger.info("Quest #{quest.id} auto-approved after #{@approval_timeout_hours}h timeout (dark factory mode)")
            Hive.HumanGate.approve(quest.id, %{approved_by: "auto_timeout", notes: "Auto-approved after #{@approval_timeout_hours}h (re-validated)"})
            {:ok, quest} = Hive.Quests.get(quest.id)
            start_merge(quest)
          else
            Logger.warning("Quest #{quest.id} re-validation failed, rejecting auto-approve")
            Hive.HumanGate.reject(quest.id, "Re-validation failed during auto-approve")
            Hive.Quests.transition_phase(quest.id, "completed", "Auto-approve failed re-validation")
            Hive.Quests.update_status!(quest.id)
            {:ok, "completed"}
          end
        else
          {:ok, "awaiting_approval"}
        end

      :not_required ->
        {:ok, quest} = Hive.Quests.get(quest.id)
        start_merge(quest)
    end
  end

  defp revalidate_quest(quest) do
    # Quick re-validation: check that implementation jobs still pass verification
    impl_jobs =
      quest.jobs
      |> Enum.reject(& &1[:phase_job])
      |> Enum.filter(&(&1.status == "done"))

    if impl_jobs == [] do
      true
    else
      # Spot-check: verify a sample of completed jobs (max 3)
      sample = Enum.take(impl_jobs, 3)

      results =
        Enum.map(sample, fn job ->
          case Hive.Verification.verify_job(job.id) do
            {:ok, :pass, _} -> true
            _ -> false
          end
        end)

      # Pass if all sampled jobs still verify
      Enum.all?(results)
    end
  rescue
    e ->
      Logger.warning("Re-validation failed for quest #{quest.id}: #{Exception.message(e)}, allowing")
      true
  end

  defp approval_timed_out?(quest_id) do
    case Store.find_one(:approval_requests, fn r -> r.quest_id == quest_id and r.status == "pending" end) do
      nil -> false
      request ->
        hours_elapsed = DateTime.diff(DateTime.utc_now(), request.requested_at, :second) / 3600
        hours_elapsed > @approval_timeout_hours
    end
  end

  # -- Phase Transition Logic --------------------------------------------------

  @phase_timeout_seconds 900

  defp check_and_advance(quest, phase, next_fn) do
    artifact = Hive.Quests.get_artifact(quest.id, phase)

    if artifact do
      # Refresh quest to get latest state
      {:ok, quest} = Hive.Quests.get(quest.id)
      next_fn.(quest)
    else
      # Check if phase has been stuck too long (no artifact produced)
      transitions = Hive.Quests.get_phase_transitions(quest.id)

      phase_start =
        transitions
        |> Enum.filter(&(&1.phase == phase))
        |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
        |> List.first()

      if phase_start do
        age = DateTime.diff(DateTime.utc_now(), phase_start.inserted_at, :second)

        if age > @phase_timeout_seconds do
          # Check if there's already a running phase bee to avoid duplicate spawning
          running_phase_job = Store.find_one(:jobs, fn j ->
            j.quest_id == quest.id and
              j[:job_type] == "phase" and
              j[:phase] == phase and
              j.status in ["running", "assigned"]
          end)

          running_worker = if running_phase_job do
            case running_phase_job[:bee_id] do
              nil -> false
              bee_id ->
                case Hive.Bee.Worker.lookup(bee_id) do
                  {:ok, pid} -> Process.alive?(pid)
                  :error -> false
                end
            end
          else
            false
          end

          if running_worker do
            Logger.debug("Quest #{quest.id} phase #{phase} has running worker, skipping re-spawn")
          else
            Logger.warning("Quest #{quest.id} stuck in #{phase} for #{age}s, re-spawning phase bee")
            # Fail any stale phase jobs first
            if running_phase_job do
              Hive.Jobs.fail(running_phase_job.id)
            end

            {:ok, quest} = Hive.Quests.get(quest.id)

            case rebuild_phase_prompt(quest, phase) do
              {prompt, model} ->
                spawn_phase_bee(quest, phase, prompt, model: model)

              nil ->
                Logger.info("Phase #{phase} doesn't use phase bees, attempting advancement")
                advance_quest(quest.id)
            end
          end
        end
      end

      {:ok, phase}
    end
  end

  # Rebuild the real prompt for a phase re-spawn using available artifacts
  defp rebuild_phase_prompt(quest, phase) do
    comb = if quest.comb_id, do: Store.get(:combs, quest.comb_id)

    case phase do
      "research" ->
        {PhasePrompts.research_prompt(quest, comb), "sonnet"}

      "requirements" ->
        research = Hive.Quests.get_artifact(quest.id, "research") || %{}
        {PhasePrompts.requirements_prompt(quest, research), "sonnet"}

      "design" ->
        requirements = Hive.Quests.get_artifact(quest.id, "requirements") || %{}
        research = Hive.Quests.get_artifact(quest.id, "research") || %{}
        {PhasePrompts.design_prompt(quest, requirements, research), "opus"}

      "review" ->
        design = Hive.Quests.get_artifact(quest.id, "design") || %{}
        requirements = Hive.Quests.get_artifact(quest.id, "requirements") || %{}
        research = Hive.Quests.get_artifact(quest.id, "research") || %{}
        {PhasePrompts.review_prompt(quest, design, requirements, research), "opus"}

      "planning" ->
        design = Hive.Quests.get_artifact(quest.id, "design") || %{}
        requirements = Hive.Quests.get_artifact(quest.id, "requirements") || %{}
        review = Hive.Quests.get_artifact(quest.id, "review") || %{}
        {PhasePrompts.planning_prompt(quest, design, requirements, review), "sonnet"}

      "validation" ->
        all_artifacts = Map.get(quest, :artifacts, %{})
        {PhasePrompts.validation_prompt(quest, all_artifacts), "sonnet"}

      phase when phase in ["implementation", "merge", "awaiting_approval"] ->
        # These phases don't use phase bees — handled by job spawning,
        # merge queue, or user approval respectively. No prompt rebuild needed.
        nil

      _ ->
        {"Re-attempt #{phase} phase", "sonnet"}
    end
  rescue
    e ->
      Logger.warning("Failed to rebuild prompt for phase #{phase}: #{Exception.message(e)}")
      {"Re-attempt #{phase} phase (prompt rebuild failed)", "sonnet"}
  end

  defp handle_review_result(quest) do
    review = Hive.Quests.get_artifact(quest.id, "review")

    cond do
      is_nil(review) ->
        {:ok, "review"}

      review["approved"] == true ->
        {:ok, quest} = Hive.Quests.get(quest.id)
        start_planning(quest)

      true ->
        # Review rejected — check redesign iteration count
        redesign_count = Map.get(quest, :redesign_count, 0)

        if redesign_count < @max_redesign_iterations do
          # Go back to design with feedback
          quest_record = Store.get(:quests, quest.id)
          updated = Map.put(quest_record, :redesign_count, redesign_count + 1)
          Store.put(:quests, updated)

          {:ok, quest} = Hive.Quests.get(quest.id)
          start_design(quest)
        else
          # Max iterations reached — proceed with warnings
          Logger.warning("Quest #{quest.id} exceeded max redesign iterations, proceeding with current design")
          {:ok, quest} = Hive.Quests.get(quest.id)
          start_planning(quest)
        end
    end
  end

  defp check_implementation_complete(quest) do
    # Only consider non-phase implementation jobs
    impl_jobs = Enum.reject(quest.jobs, & &1[:phase_job])

    cond do
      impl_jobs == [] ->
        Logger.warning("Quest #{quest.id} has no implementation jobs, advancing to validation")
        if Map.get(quest, :comb_id) do
          {:ok, quest} = Hive.Quests.get(quest.id)
          start_validation(quest)
        else
          complete_quest(quest.id)
        end

      Enum.all?(impl_jobs, &(&1.status == "done")) ->
        # Only start validation if this is a new-style quest with comb_id
        if Map.get(quest, :comb_id) do
          {:ok, quest} = Hive.Quests.get(quest.id)
          start_validation(quest)
        else
          # Old-style quest: just complete it directly
          complete_quest(quest.id)
        end

      majority_failed?(impl_jobs) ->
        # >50% failed: attempt fallback plan
        attempt_fallback_plan(quest)

      Enum.any?(impl_jobs, &(&1.status == "failed")) ->
        # Let the Queen's retry logic handle failures
        {:ok, "implementation"}

      true ->
        {:ok, "implementation"}
    end
  end

  defp majority_failed?(impl_jobs) do
    terminal_jobs = Enum.filter(impl_jobs, &(&1.status in ["done", "failed"]))
    failed = Enum.count(terminal_jobs, &(&1.status == "failed"))
    total = length(terminal_jobs)

    total > 0 and failed / total > 0.5
  end

  defp attempt_fallback_plan(quest) do
    case Planner.select_fallback_plan(quest.id) do
      {:ok, fallback} ->
        Logger.warning(
          "Quest #{quest.id}: >50% impl jobs failed, switching to fallback plan (#{fallback.strategy})"
        )

        # Record tried plan
        quest_record = Store.get(:quests, quest.id)

        if quest_record do
          tried = Map.get(quest_record, :tried_plans, [])
          current_plan = Map.get(quest_record, :draft_plan, %{})
          updated = Map.put(quest_record, :tried_plans, [current_plan | tried])
          Store.put(:quests, updated)
        end

        # Re-enter implementation with fallback plan
        specs = fallback.tasks

        case specs do
          tasks when is_list(tasks) and tasks != [] ->
            Planner.create_jobs_from_specs(quest.id, tasks)

            {:ok, quest} = Hive.Quests.get(quest.id)
            spawn_implementation_jobs(quest)
            {:ok, "implementation"}

          _ ->
            Logger.warning("Fallback plan has no tasks, staying in implementation")
            {:ok, "implementation"}
        end

      {:error, :no_fallback} ->
        # Adaptive re-decomposition: replan from failure context
        replan_count = Map.get(quest, :replan_count, 0)

        if replan_count < 2 do
          Logger.info("Quest #{quest.id}: no fallback plans, attempting replan (#{replan_count + 1}/2)")

          # Increment replan count
          quest_record = Store.get(:quests, quest.id)

          if quest_record do
            updated = Map.put(quest_record, :replan_count, replan_count + 1)
            Store.put(:quests, updated)
          end

          case Planner.replan_from_failures(quest.id) do
            {:ok, replan} ->
              specs = replan.tasks

              case specs do
                tasks when is_list(tasks) and tasks != [] ->
                  Planner.create_jobs_from_specs(quest.id, tasks)
                  {:ok, quest} = Hive.Quests.get(quest.id)
                  spawn_implementation_jobs(quest)
                  {:ok, "implementation"}

                _ ->
                  Logger.warning("Replan produced no tasks for quest #{quest.id}")
                  fail_exhausted_quest(quest)
              end

            {:error, reason} ->
              Logger.warning("Replan failed for quest #{quest.id}: #{inspect(reason)}")
              fail_exhausted_quest(quest)
          end
        else
          Logger.warning("Quest #{quest.id}: all recovery strategies exhausted (fallback + #{replan_count} replans)")
          fail_exhausted_quest(quest)
        end
    end
  end

  defp fail_exhausted_quest(quest) do
    Logger.warning("Quest #{quest.id} implementation exhausted — all plans, fallbacks, and replans failed")

    # Collect what DID succeed for partial credit
    impl_jobs = Enum.reject(quest.jobs, & &1[:phase_job])
    done_count = Enum.count(impl_jobs, &(&1.status == "done"))
    total_count = length(impl_jobs)

    Hive.Quests.store_artifact(quest.id, "implementation_exhausted", %{
      "reason" => "All recovery strategies exhausted",
      "completed_jobs" => done_count,
      "total_jobs" => total_count,
      "replan_count" => Map.get(quest, :replan_count, 0)
    })

    if done_count > 0 do
      # Some jobs succeeded — attempt validation of partial work
      Logger.info("Quest #{quest.id}: #{done_count}/#{total_count} jobs completed, attempting partial validation")
      {:ok, quest} = Hive.Quests.get(quest.id)
      start_validation(quest)
    else
      # Nothing succeeded — fail the quest
      Hive.Quests.transition_phase(quest.id, "completed", "Implementation exhausted: all plans failed")
      Hive.Quests.update_status!(quest.id)

      Hive.Telemetry.emit([:hive, :alert, :raised], %{}, %{
        type: :quest_exhausted,
        message: "Quest #{quest.id} failed: all implementation strategies exhausted"
      })

      {:ok, "completed"}
    end
  end

  @max_validation_fix_attempts 2

  defp handle_validation_result(quest) do
    validation = Hive.Quests.get_artifact(quest.id, "validation")

    cond do
      is_nil(validation) ->
        {:ok, "validation"}

      validation["overall_verdict"] == "pass" ->
        # Check if human approval is required before merge
        if Hive.HumanGate.requires_approval?(quest) do
          start_awaiting_approval(quest)
        else
          start_merge(quest)
        end

      true ->
        # Validation failed — attempt targeted fixes before giving up
        fix_attempt = Map.get(quest, :validation_fix_count, 0)

        if fix_attempt < @max_validation_fix_attempts do
          Logger.info("Quest #{quest.id} validation failed (attempt #{fix_attempt + 1}/#{@max_validation_fix_attempts}), creating fix jobs")
          attempt_validation_fixes(quest, validation, fix_attempt)
        else
          Logger.warning("Quest #{quest.id} validation failed after #{fix_attempt} fix attempts: #{validation["summary"]}")
          Hive.Quests.transition_phase(quest.id, "completed", "Validation failed after #{fix_attempt} fix attempts")
          Hive.Quests.update_status!(quest.id)
          {:ok, "completed"}
        end
    end
  end

  defp attempt_validation_fixes(quest, validation, fix_attempt) do
    # Increment fix attempt counter
    quest_record = Store.get(:quests, quest.id)

    if quest_record do
      updated = Map.put(quest_record, :validation_fix_count, fix_attempt + 1)
      Store.put(:quests, updated)
    end

    # Extract specific gaps from validation artifact
    gaps = Map.get(validation, "gaps", [])
    unmet = (Map.get(validation, "requirements_met", []) || [])
            |> Enum.filter(fn r -> Map.get(r, "met") == false end)

    fix_specs =
      cond do
        # Create fix jobs from unmet requirements
        unmet != [] ->
          Enum.map(unmet, fn req ->
            %{
              "title" => "Fix: #{Map.get(req, "req_id", "unknown")} — #{Map.get(req, "evidence", "validation failed")}",
              "description" => """
              The validation phase found this requirement was NOT met.

              Requirement: #{Map.get(req, "req_id", "unknown")}
              Evidence: #{Map.get(req, "evidence", "No details")}

              Fix this specific issue. Check the existing implementation and make the minimal changes needed.
              """,
              "job_type" => "fix"
            }
          end)

        # Create fix jobs from gap descriptions
        gaps != [] ->
          Enum.map(gaps, fn gap ->
            %{
              "title" => "Fix validation gap: #{String.slice(to_string(gap), 0, 60)}",
              "description" => """
              The validation phase identified this gap:

              #{gap}

              Fix this specific issue with minimal changes.
              """,
              "job_type" => "fix"
            }
          end)

        # Fallback: single fix job from summary
        true ->
          summary = Map.get(validation, "summary", "Validation failed")
          [%{
            "title" => "Fix validation issues: #{String.slice(summary, 0, 60)}",
            "description" => "Validation failed: #{summary}\n\nFix all identified issues.",
            "job_type" => "fix"
          }]
      end

    if fix_specs != [] do
      Planner.create_jobs_from_specs(quest.id, fix_specs)

      # Transition back to implementation to run the fix jobs
      Hive.Quests.transition_phase(quest.id, "implementation", "Validation fix attempt #{fix_attempt + 1}")
      {:ok, quest} = Hive.Quests.get(quest.id)
      spawn_implementation_jobs(quest)
      {:ok, "implementation"}
    else
      Logger.warning("Quest #{quest.id}: no fixable issues extracted from validation")
      Hive.Quests.transition_phase(quest.id, "completed", "Validation failed, no fixable issues identified")
      Hive.Quests.update_status!(quest.id)
      {:ok, "completed"}
    end
  rescue
    e ->
      Logger.warning("Validation fix attempt failed for quest #{quest.id}: #{Exception.message(e)}")
      Hive.Quests.transition_phase(quest.id, "completed", "Validation fix attempt crashed")
      Hive.Quests.update_status!(quest.id)
      {:ok, "completed"}
  end

  defp complete_quest(quest_id) do
    with {:ok, _} <- Hive.Quests.transition_phase(quest_id, "completed", "All phases complete") do
      Hive.Quests.update_status!(quest_id)

      # Start post-review if enabled for this comb
      with {:ok, quest} <- Hive.Quests.get(quest_id),
           comb_id when not is_nil(comb_id) <- quest.comb_id,
           true <- Hive.PostReview.enabled?(comb_id) do
        Hive.PostReview.start_review(quest_id)
      end

      {:ok, "completed"}
    end
  end

  # -- Bee Spawning ------------------------------------------------------------

  defp spawn_phase_bee(quest, phase, prompt, opts) do
    model = Keyword.get(opts, :model, "sonnet")

    # Create a phase job
    job_attrs = %{
      title: "#{String.capitalize(phase)} phase for: #{String.slice(quest.goal, 0, 60)}",
      description: prompt,
      quest_id: quest.id,
      comb_id: quest.comb_id,
      phase_job: true,
      phase: phase,
      assigned_model: model_id(model)
    }

    case Hive.Jobs.create(job_attrs) do
      {:ok, job} ->
        # Record which job serves which phase
        Hive.Quests.record_phase_job(quest.id, phase, job.id)

        # Spawn the bee
        case Hive.hive_dir() do
          {:ok, hive_root} ->
            case Hive.Bees.spawn_detached(job.id, quest.comb_id, hive_root, prompt: prompt) do
              {:ok, bee} ->
                Logger.info("Phase bee #{bee.id} spawned for #{phase} phase of quest #{quest.id}")
                {:ok, bee}

              {:error, reason} ->
                Logger.error("Failed to spawn #{phase} phase bee: #{inspect(reason)}")
                {:error, reason}
            end

          {:error, reason} ->
            Logger.error("Cannot spawn phase bee — no hive root: #{inspect(reason)}")
            {:error, :no_hive_root}
        end

      {:error, reason} ->
        Logger.error("Failed to create #{phase} phase job: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp spawn_implementation_jobs(quest) do
    case Hive.hive_dir() do
      {:ok, hive_root} ->
        quest.jobs
        |> Enum.reject(& &1[:phase_job])
        |> Enum.filter(&(&1.status == "pending"))
        |> Enum.filter(&Hive.Jobs.ready?(&1.id))
        |> Enum.each(fn job ->
          case Hive.Bees.spawn_detached(job.id, job.comb_id, hive_root) do
            {:ok, _bee} -> :ok
            {:error, _reason} -> :ok
          end
        end)

      {:error, _} ->
        :ok
    end
  end

  defp generate_synthetic_jobs(quest) do
    # Try to derive tasks from requirements artifact
    requirements = Hive.Quests.get_artifact(quest.id, "requirements")
    design = Hive.Quests.get_artifact(quest.id, "design")

    specs =
      cond do
        is_map(requirements) and is_list(requirements["functional_requirements"]) ->
          requirements["functional_requirements"]
          |> Enum.with_index(1)
          |> Enum.map(fn {req, idx} ->
            %{
              "title" => "Implement requirement #{idx}: #{String.slice(to_string(req["name"] || req), 0, 60)}",
              "description" => to_string(req["description"] || req),
              "job_type" => "implementation"
            }
          end)

        is_map(design) and is_list(design["components"]) ->
          design["components"]
          |> Enum.map(fn comp ->
            %{
              "title" => "Implement component: #{String.slice(to_string(comp["name"] || comp), 0, 60)}",
              "description" => to_string(comp["description"] || Jason.encode!(comp)),
              "job_type" => "implementation"
            }
          end)

        true ->
          # Last resort: single job from quest goal
          [%{
            "title" => "Implement: #{String.slice(quest.goal, 0, 80)}",
            "description" => quest.goal,
            "job_type" => "implementation"
          }]
      end

    if specs != [] do
      Logger.info("Quest #{quest.id}: generated #{length(specs)} synthetic jobs from artifacts")
      Planner.create_jobs_from_specs(quest.id, specs)
    end

    {:ok, specs}
  rescue
    e ->
      Logger.warning("Synthetic job generation failed for quest #{quest.id}: #{Exception.message(e)}")
      {:ok, []}
  end

  defp is_client_facing?(quest) do
    text = String.downcase(quest.goal)

    Enum.any?(
      ["ui", "client", "frontend", "web", "user interface", "ux", "dashboard", "app"],
      &String.contains?(text, &1)
    )
  end

  # -- Helpers -----------------------------------------------------------------

  defp validate_quest_ready(quest) do
    cond do
      is_nil(Map.get(quest, :comb_id)) -> {:error, :no_comb_assigned}
      Map.get(quest, :status) not in ["pending", "active", "planning"] -> {:error, :quest_not_pending}
      true -> :ok
    end
  end

  defp model_id(tier) do
    Hive.Runtime.ModelResolver.resolve(tier)
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
            "#{length(artifact)} jobs planned"

          "validation" ->
            Map.get(artifact, "overall_verdict", "unknown")

          _ ->
            "completed"
        end

      {phase, summary}
    end)
  end
end
