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

  @phases ~w(research requirements design review planning implementation validation merge)
  @max_redesign_iterations 2

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

        other ->
          {:ok, other}
      end
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

      # Generate expert agents for design phase
      experts = discover_design_experts(quest, research)

      spawn_phase_bee(quest, "design", prompt,
        model: "opus",
        council_experts: experts
      )

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
      # Create real implementation jobs from the planning artifact
      case planning_artifact do
        specs when is_list(specs) ->
          Planner.create_jobs_from_specs(quest.id, specs)

        _ ->
          Logger.warning("Planning artifact is not a list, falling back to basic planning")
          {:ok, []}
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
          Logger.warning("Quest #{quest.id} merge failed: #{inspect(reason)}")
          {:ok, "merge"}
      end
    end
  end

  # -- Phase Transition Logic --------------------------------------------------

  defp check_and_advance(quest, phase, next_fn) do
    artifact = Hive.Quests.get_artifact(quest.id, phase)

    if artifact do
      # Refresh quest to get latest state
      {:ok, quest} = Hive.Quests.get(quest.id)
      next_fn.(quest)
    else
      {:ok, phase}
    end
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
        {:ok, "implementation"}

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
                  {:ok, "implementation"}
              end

            {:error, reason} ->
              Logger.warning("Replan failed for quest #{quest.id}: #{inspect(reason)}")
              {:ok, "implementation"}
          end
        else
          Logger.warning("Quest #{quest.id}: replan limit reached (#{replan_count}), staying in implementation")
          {:ok, "implementation"}
        end
    end
  end

  defp handle_validation_result(quest) do
    validation = Hive.Quests.get_artifact(quest.id, "validation")

    cond do
      is_nil(validation) ->
        {:ok, "validation"}

      validation["overall_verdict"] == "pass" ->
        start_merge(quest)

      true ->
        # Validation failed — mark quest as needing attention
        Logger.warning("Quest #{quest.id} failed validation: #{validation["summary"]}")
        Hive.Quests.transition_phase(quest.id, "completed", "Validation completed with issues")
        Hive.Quests.update_status!(quest.id)
        {:ok, "completed"}
    end
  end

  defp complete_quest(quest_id) do
    with {:ok, _} <- Hive.Quests.transition_phase(quest_id, "completed", "All phases complete") do
      Hive.Quests.update_status!(quest_id)
      {:ok, "completed"}
    end
  end

  # -- Bee Spawning ------------------------------------------------------------

  defp spawn_phase_bee(quest, phase, prompt, opts) do
    model = Keyword.get(opts, :model, "sonnet")
    council_experts = Keyword.get(opts, :council_experts)

    # Create a phase job
    job_attrs = %{
      title: "#{String.capitalize(phase)} phase for: #{String.slice(quest.goal, 0, 60)}",
      description: prompt,
      quest_id: quest.id,
      comb_id: quest.comb_id,
      phase_job: true,
      phase: phase,
      assigned_model: model_id(model),
      council_experts: council_experts
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

  # -- Expert Integration ------------------------------------------------------

  defp discover_design_experts(quest, research) do
    # Infer domain from research and goal
    tech_stack = if research, do: Map.get(research, "tech_stack", []), else: []
    domain = infer_domain(quest.goal, tech_stack)

    case Code.ensure_loaded(Hive.Council.Generator) do
      {:module, _} ->
        case Hive.Council.Generator.discover_experts(domain, experts: 3) do
          {:ok, experts} ->
            Enum.map(experts, & &1.key)

          {:error, _reason} ->
            nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp infer_domain(goal, tech_stack) do
    stack_str = if is_list(tech_stack), do: Enum.join(tech_stack, ", "), else: ""
    "#{goal} (#{stack_str})"
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
