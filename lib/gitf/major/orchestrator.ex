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

  @phases ~w(research requirements design review planning implementation validation awaiting_approval sync simplify scoring)
  @default_max_redesign 2

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
         :ok <- provider_preflight() do
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

      GiTF.Missions.update(mission_id, %{pipeline_mode: pipeline_mode})

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
          start_research(mission)
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
        quest_record = Archive.get(:missions, mission_id)

        updated =
          quest_record
          |> Map.put(:redesign_count, redesign_count + 1)
          |> Map.put(:redesign_reason, reason)

        Archive.put(:missions, updated)

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
      :ok -> {:ok, :already_advancing}
      other -> other
    end
  end

  defp do_advance_quest(mission_id) do
    with {:ok, mission} <- GiTF.Missions.get(mission_id) do
      if quest_timed_out?(mission) do
        timeout_h = max_quest_age_hours()
        Logger.warning("Quest #{mission_id} exceeded #{timeout_h}h max age, force-completing")

        GiTF.Telemetry.emit([:gitf, :alert, :raised], %{}, %{
          type: :quest_timeout,
          message: "Quest #{mission_id} force-completed after #{timeout_h}h timeout"
        })

        fail_quest(mission_id, "Quest timed out after #{timeout_h}h")
      else
        advance_mission_phase(mission)
      end
    end
  end

  defp quest_timed_out?(mission) do
    case mission[:inserted_at] do
      %DateTime{} = started ->
        hours = DateTime.diff(DateTime.utc_now(), started, :second) / 3600
        phase = Map.get(mission, :current_phase, "pending")
        # Don't timeout missions that are completed or awaiting approval
        phase not in ["completed", "awaiting_approval", "pending"] and
          hours > max_quest_age_hours()

      _ ->
        false
    end
  end

  defp advance_mission_phase(mission) do
    phase = Map.get(mission, :current_phase, "pending")

    case phase do
      "pending" ->
        # Only start research if mission has a sector_id (new-style missions)
        if Map.get(mission, :sector_id) do
          start_research(mission)
        else
          {:ok, phase}
        end

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
        handle_validation_result(mission)

      "awaiting_approval" ->
        handle_approval_result(mission)

      "sync" ->
        check_and_advance(mission, "sync", &start_simplify/1)

      "simplify" ->
        check_simplify_complete(mission)

      "scoring" ->
        check_and_advance(mission, "scoring", &finish_scored/1)

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

  defp start_research(mission) do
    sector_id = Map.get(mission, :sector_id)

    if is_nil(sector_id) do
      {:error, :no_sector_assigned}
    else
      with {:ok, _} <- GiTF.Missions.transition_phase(mission.id, "research", "Quest started") do
        sector = Archive.get(:sectors, sector_id)
        ctx = GiTF.Intel.get_prompt_context(sector_id, "research")
        prompt = PhasePrompts.research_prompt(mission, sector, ctx)
        spawn_phase_ghost(mission, "research", prompt, model: "general")
        {:ok, "research"}
      end
    end
  end

  defp start_requirements(mission) do
    research = GiTF.Missions.get_artifact(mission.id, "research")

    with {:ok, _} <-
           GiTF.Missions.transition_phase(mission.id, "requirements", "Research complete") do
      ctx = GiTF.Intel.get_prompt_context(mission.sector_id, "requirements")
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

    with {:ok, _} <- GiTF.Missions.transition_phase(mission.id, "design", "Requirements complete") do
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
      quest_record = Archive.get(:missions, mission.id)

      if quest_record do
        Archive.put(
          :missions,
          Map.put(quest_record, :design_strategy_count, length(strategies))
        )
      end

      ctx = GiTF.Intel.get_prompt_context(mission.sector_id, "design")

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
          model: "thinking",
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

    with {:ok, _} <- GiTF.Missions.transition_phase(mission.id, "review", "Design complete") do
      prompt = PhasePrompts.review_prompt(mission, designs, requirements, research)
      spawn_phase_ghost(mission, "review", prompt, model: "thinking")
      {:ok, "review"}
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

    with {:ok, _} <- GiTF.Missions.transition_phase(mission.id, "planning", "Review approved") do
      ctx = GiTF.Intel.get_prompt_context(mission.sector_id, "planning")
      prompt = PhasePrompts.planning_prompt(mission, design, requirements, review, ctx)
      spawn_phase_ghost(mission, "planning", prompt, model: "thinking")
      {:ok, "planning"}
    end
  end

  defp start_implementation(mission) do
    planning_artifact = GiTF.Missions.get_artifact(mission.id, "planning")

    with {:ok, _} <-
           GiTF.Missions.transition_phase(mission.id, "implementation", "Planning complete") do
      # Planning phase already scored and selected the best plan.
      # Just create ops from whatever planning artifact exists.
      case planning_artifact do
        specs when is_list(specs) and specs != [] ->
          Planner.create_jobs_from_specs(mission.id, specs)

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

  defp start_validation(mission) do
    requirements = GiTF.Missions.get_artifact(mission.id, "requirements")
    planning = GiTF.Missions.get_artifact(mission.id, "planning")

    with {:ok, _} <-
           GiTF.Missions.transition_phase(mission.id, "validation", "Implementation complete") do
      ctx = GiTF.Intel.get_prompt_context(mission.sector_id, "validation")
      prompt = PhasePrompts.validation_prompt(mission, requirements, planning, ctx)
      spawn_phase_ghost(mission, "validation", prompt, model: "general")
      {:ok, "validation"}
    end
  end

  defp start_merge(mission) do
    with {:ok, _} <-
           GiTF.Missions.transition_phase(mission.id, "sync", "Validation passed, merging") do
      sector = if mission.sector_id, do: Archive.get(:sectors, mission.sector_id)

      strategy =
        if sector, do: Map.get(sector, :sync_strategy) || "auto_merge", else: "auto_merge"

      case strategy do
        "manual" ->
          GiTF.Missions.store_artifact(mission.id, "sync", %{
            "status" => "manual",
            "note" => "Branches left for manual merge"
          })

          # Sync artifact stored — advance_mission_phase will pick up simplify
          {:ok, "sync"}

        "pr_branch" ->
          finalize_merge_as_pr(mission, sector)

        _ ->
          finalize_merge_to_main(mission)
      end
    end
  end

  defp finalize_merge_to_main(mission) do
    with {:ok, sector} <- fetch_sector(mission.sector_id),
         {:ok, quest_branch} <- GiTF.Sync.merge_quest(mission.id) do
      repo_path = sector.path

      # Capture pre-merge HEAD so we can audit and (later) revert if needed
      main_before_sha =
        case GiTF.Git.head_sha(repo_path) do
          {:ok, sha} -> sha
          _ -> nil
        end

      with {:ok, main_branch} <- GiTF.Sync.detect_main_branch(repo_path),
           :ok <- GiTF.Git.checkout(repo_path, main_branch),
           :ok <- GiTF.Git.sync(repo_path, quest_branch, no_ff: true),
           {:ok, merge_commit_sha} <- GiTF.Git.head_sha(repo_path) do
        GiTF.Missions.store_artifact(mission.id, "sync", %{
          "status" => "success",
          "branch" => quest_branch,
          "merged_at" => DateTime.utc_now(),
          "merge_commit_sha" => merge_commit_sha,
          "main_before_sha" => main_before_sha,
          "main_branch" => main_branch,
          "revertible" => true
        })

        {:ok, mission} = GiTF.Missions.get(mission.id)
        start_simplify(mission)
      else
        {:error, reason} ->
          Logger.warning(
            "Quest #{mission.id} merge of mission branch failed: #{inspect(reason)}"
          )

          GiTF.Missions.store_artifact(mission.id, "sync", %{
            "status" => "failed",
            "branch" => quest_branch,
            "error" => inspect(reason)
          })

          fail_quest(mission.id, "Sync failed: #{inspect(reason)}")
      end
    else
      {:error, reason} ->
        GiTF.Missions.store_artifact(mission.id, "sync", %{
          "status" => "failed",
          "error" => inspect(reason)
        })

        Logger.warning("Quest #{mission.id} sync failed: #{inspect(reason)}")
        fail_quest(mission.id, "Sync failed: #{inspect(reason)}")
    end
  end

  defp finalize_merge_as_pr(mission, nil), do: finalize_merge_to_main(mission)

  defp finalize_merge_as_pr(mission, sector) do
    with {:ok, quest_branch} <- GiTF.Sync.merge_quest(mission.id),
         repo_path = sector.path,
         {:ok, main_branch} <- GiTF.Sync.detect_main_branch(repo_path) do
      title = "gitf: #{mission.name || mission.goal}"

      body =
        """
        Mission #{mission.id}

        **Goal:** #{mission.goal}
        """
        |> GiTF.Signature.sign()

      # Push mission branch and create PR
      GiTF.Git.safe_cmd(["push", "-u", "origin", quest_branch],
        cd: repo_path,
        stderr_to_stdout: true
      )

      # Wrap in Task with timeout — a hung `gh` would hold the MissionLock forever
      pr_task =
        Task.Supervisor.async_nolink(GiTF.TaskSupervisor, fn ->
          System.cmd(
            "gh",
            [
              "pr",
              "create",
              "--head",
              quest_branch,
              "--base",
              main_branch,
              "--title",
              String.slice(title, 0, 200),
              "--body",
              String.slice(body, 0, 4000)
            ],
            cd: repo_path,
            stderr_to_stdout: true
          )
        end)

      pr_result =
        case Task.yield(pr_task, 30_000) || Task.shutdown(pr_task, :brutal_kill) do
          {:ok, {output, 0}} -> {:ok, String.trim(output)}
          {:ok, {output, _}} -> {:error, String.slice(output, 0, 200)}
          nil -> {:error, "gh pr create timed out after 30s"}
        end

      case pr_result do
        {:ok, url} ->
          GiTF.Missions.store_artifact(mission.id, "sync", %{
            "status" => "pr_created",
            "branch" => quest_branch,
            "pr_url" => url
          })

        {:error, reason} ->
          Logger.warning("Quest #{mission.id} PR creation failed: #{inspect(reason)}")

          GiTF.Missions.store_artifact(mission.id, "sync", %{
            "status" => "pr_failed",
            "branch" => quest_branch,
            "error" => inspect(reason)
          })
      end

      {:ok, mission} = GiTF.Missions.get(mission.id)
      start_simplify(mission)
    else
      {:error, reason} ->
        GiTF.Missions.store_artifact(mission.id, "sync", %{
          "status" => "failed",
          "error" => inspect(reason)
        })

        Logger.warning("Quest #{mission.id} PR merge failed: #{inspect(reason)}")
        GiTF.Missions.transition_phase(mission.id, "completed", "Sync failed: #{inspect(reason)}")
        GiTF.Missions.update_status!(mission.id)
        {:ok, "completed"}
    end
  rescue
    e ->
      Logger.warning("Quest #{mission.id} PR finalization failed: #{Exception.message(e)}")

      GiTF.Missions.store_artifact(mission.id, "sync", %{
        "status" => "failed",
        "error" => Exception.message(e)
      })

      fail_quest(mission.id, "PR finalization failed")
  end

  defp start_awaiting_approval(mission) do
    with {:ok, _} <-
           GiTF.Missions.transition_phase(
             mission.id,
             "awaiting_approval",
             "Validation passed, awaiting human approval"
           ) do
      GiTF.Override.request_approval(mission.id)

      GiTF.Observability.Alerts.dispatch_webhook(
        :approval_requested,
        "Quest #{mission.id} awaiting human approval: #{String.slice(mission.goal, 0, 80)}"
      )

      {:ok, "awaiting_approval"}
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

          # Fast mode: single design, skip review → go straight to planning
          if FastPath.fast_mode?(mission) do
            promote_selected_design(mission.id, %{"selected_design" => "minimal"})
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

  defp extract_strategy_from_title(title) do
    case Regex.run(~r/\[([^\]]+)\]/, title) do
      [_, strategy] -> strategy
      _ -> "normal"
    end
  end

  defp handle_approval_result(mission) do
    case GiTF.Override.approval_status(mission.id) do
      :approved ->
        {:ok, mission} = GiTF.Missions.get(mission.id)
        start_merge(mission)

      :rejected ->
        Logger.warning("Quest #{mission.id} rejected by human reviewer")
        fail_quest(mission.id, "Human review rejected")

      :pending ->
        # Check for approval timeout — re-validate then auto-approve
        if approval_timed_out?(mission.id) do
          timeout_h = approval_timeout_hours()

          # Critical-risk missions never auto-approve — alert instead
          if mission_max_risk(mission.id) == :critical do
            Logger.warning(
              "Quest #{mission.id} timeout reached but mission is critical-risk, refusing auto-approve"
            )

            GiTF.Observability.Alerts.dispatch_webhook(
              :approval_timeout_critical,
              "Quest #{mission.id} timed out after #{timeout_h}h but is critical-risk — requires human approval"
            )

            {:ok, "awaiting_approval"}
          else
            # Re-validate before auto-approving to catch regressions
            validation_fresh? = revalidate_quest(mission)

            if validation_fresh? do
              Logger.info(
                "Quest #{mission.id} auto-approved after #{timeout_h}h timeout (dark factory mode)"
              )

              GiTF.Override.approve(mission.id, %{
                approved_by: "auto_timeout",
                notes: "Auto-approved after #{timeout_h}h (re-validated)"
              })

              {:ok, mission} = GiTF.Missions.get(mission.id)
              start_merge(mission)
            else
              Logger.warning("Quest #{mission.id} re-validation failed, rejecting auto-approve")

              GiTF.Override.reject(mission.id, "Re-validation failed during auto-approve", %{
                rejected_by: "auto_timeout"
              })

              fail_quest(mission.id, "Auto-approve failed re-validation")
            end
          end
        else
          {:ok, "awaiting_approval"}
        end

      :not_required ->
        {:ok, mission} = GiTF.Missions.get(mission.id)
        start_merge(mission)
    end
  end

  defp revalidate_quest(mission) do
    # Quick re-validation: check that implementation ops still pass verification
    impl_jobs =
      for op <- mission.ops, !op[:phase_job], op.status == "done", do: op

    if impl_jobs == [] do
      true
    else
      # Spot-check: verify a sample of completed ops (max 3)
      sample = Enum.take(impl_jobs, 3)

      results =
        Enum.map(sample, fn op ->
          case GiTF.Audit.verify_job(op.id) do
            {:ok, :pass, _} -> true
            _ -> false
          end
        end)

      # Pass if all sampled ops still verify
      Enum.all?(results)
    end
  rescue
    e ->
      Logger.warning(
        "Re-validation crashed for mission #{mission.id}: #{Exception.message(e)}, rejecting"
      )

      false
  end

  defp approval_timed_out?(mission_id) do
    case Archive.find_one(:approval_requests, fn r ->
           r.mission_id == mission_id and r.status == "pending"
         end) do
      nil ->
        false

      request ->
        hours_elapsed = DateTime.diff(DateTime.utc_now(), request.requested_at, :second) / 3600
        hours_elapsed > approval_timeout_hours()
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
        age = DateTime.diff(DateTime.utc_now(), phase_start.inserted_at, :second)
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

      if complexity == "low" and Map.get(mission, :pipeline_mode) != "full" do
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
      check_and_advance(mission, "research", &start_requirements/1)
    end
  end

  # Rebuild the real prompt for a phase re-spawn using available artifacts
  defp rebuild_phase_prompt(mission, phase) do
    sector = if mission.sector_id, do: Archive.get(:sectors, mission.sector_id)
    ctx = GiTF.Intel.get_prompt_context(mission.sector_id, phase)

    case phase do
      "research" ->
        {PhasePrompts.research_prompt(mission, sector, ctx), "general"}

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
        {PhasePrompts.validation_prompt(mission, requirements, planning, ctx), "general"}

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
          quest_record = Archive.get(:missions, mission.id)
          updated = Map.put(quest_record, :redesign_count, redesign_count + 1)
          Archive.put(:missions, updated)

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

  defp promote_selected_design(mission_id, review) do
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

      majority_failed?(impl_jobs) ->
        # >50% failed: attempt fallback plan
        attempt_fallback_plan(mission)

      Enum.any?(impl_jobs, &(&1.status in ["failed", "rejected"])) ->
        # Check if all failed ops have exhausted retries — if so, no more progress
        # is possible and we should escalate to fallback rather than spinning forever
        failed_ops = Enum.filter(impl_jobs, &(&1.status in ["failed", "rejected"]))

        all_exhausted =
          Enum.all?(failed_ops, fn op ->
            Map.get(op, :retry_count, 0) >= 3
          end)

        if all_exhausted do
          Logger.warning(
            "Quest #{mission.id}: #{length(failed_ops)} ops failed with retries exhausted, escalating"
          )

          attempt_fallback_plan(mission)
        else
          # Retries still in flight — let retry logic handle it
          {:ok, "implementation"}
        end

      true ->
        {:ok, "implementation"}
    end
  end

  defp majority_failed?(impl_jobs) do
    terminal_jobs = for op <- impl_jobs, op.status in ["done", "failed"], do: op
    failed = Enum.count(terminal_jobs, &(&1.status == "failed"))
    total = length(terminal_jobs)

    total > 0 and failed / total > 0.5
  end

  defp attempt_fallback_plan(mission) do
    case Planner.select_fallback_plan(mission.id) do
      {:ok, fallback} ->
        Logger.warning(
          "Quest #{mission.id}: >50% impl ops failed, switching to fallback plan (#{fallback.strategy})"
        )

        # Record tried plan
        quest_record = Archive.get(:missions, mission.id)

        if quest_record do
          tried = Map.get(quest_record, :tried_plans, [])
          current_plan = Map.get(quest_record, :draft_plan, %{})
          updated = Map.put(quest_record, :tried_plans, [current_plan | tried])
          Archive.put(:missions, updated)
        end

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

          # Bump replan count before attempting
          quest_record = Archive.get(:missions, mission.id)

          if quest_record,
            do: Archive.put(:missions, Map.put(quest_record, :replan_count, replan_count + 1))

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

      GiTF.Telemetry.emit([:gitf, :alert, :raised], %{}, %{
        type: :quest_exhausted,
        message: "Quest #{mission.id} failed: all implementation strategies exhausted"
      })

      {:ok, "completed"}
    end
  end

  @default_max_fix_attempts 2

  defp handle_validation_result(mission) do
    validation = GiTF.Missions.get_artifact(mission.id, "validation")

    cond do
      is_nil(validation) ->
        {:ok, "validation"}

      validation["overall_verdict"] == "pass" ->
        # Check if human approval is required before sync
        if GiTF.Override.requires_approval?(mission) do
          start_awaiting_approval(mission)
        else
          start_merge(mission)
        end

      true ->
        # Validation failed — use Togusa's fix context for accumulated tracking
        fix_ctx = load_mission_fix_context(mission)

        if GiTF.Togusa.FixContext.exhausted?(fix_ctx) do
          Logger.warning(
            "Quest #{mission.id} validation failed after #{fix_ctx.attempt} fix attempts"
          )

          fail_quest(mission.id, "Validation failed after #{fix_ctx.attempt} fix attempts")
        else
          Logger.info(
            "Quest #{mission.id} validation failed (attempt #{fix_ctx.attempt + 1}/#{fix_ctx.max_attempts})"
          )

          attempt_validation_fixes(mission, validation, fix_ctx)
        end
    end
  end

  defp attempt_validation_fixes(mission, validation, %GiTF.Togusa.FixContext{} = fix_ctx) do
    impl_files = get_mission_changed_files(mission)

    # Build fix description with full validation feedback
    fix_description = build_fix_description(mission, validation, impl_files)

    # Record this attempt in the fix context
    fix_ctx =
      GiTF.Togusa.FixContext.record_attempt(
        fix_ctx,
        :goal_fulfillment,
        mission.id,
        validation,
        fix_description
      )

    # Persist updated fix context on the mission record
    store_mission_fix_context(mission.id, fix_ctx)

    # Learn from failure (agent profile improvement — previously missing from orchestrator)
    learn_from_validation_failure(mission, validation)

    shell = find_implementation_shell(mission)

    # Include fix history in the prompt so the ghost sees all prior attempts
    history_prompt = GiTF.Togusa.FixContext.format_for_prompt(fix_ctx)
    full_description = fix_description <> "\n" <> history_prompt

    fix_title = "Fix validation issues (attempt #{fix_ctx.attempt})"

    case GiTF.Ops.create(%{
           title: fix_title,
           description: full_description,
           mission_id: mission.id,
           sector_id: mission.sector_id,
           phase_job: false,
           skip_verification: false,
           fix_context: GiTF.Togusa.FixContext.to_map(fix_ctx),
           fix_of: fix_ctx.original_op_id,
           target_files: impl_files
         }) do
      {:ok, fix_op} ->
        GiTF.Missions.transition_phase(
          mission.id,
          "implementation",
          "Validation fix attempt #{fix_ctx.attempt}"
        )

        if shell do
          spawn_fix_in_worktree(fix_op, shell, mission)
        else
          {:ok, mission} = GiTF.Missions.get(mission.id)
          spawn_implementation_jobs(mission)
        end

        {:ok, "implementation"}

      {:error, reason} ->
        Logger.warning("Quest #{mission.id}: failed to create fix op: #{inspect(reason)}")
        fail_quest(mission.id, "Could not create fix op")
    end
  rescue
    e ->
      Logger.warning(
        "Validation fix attempt failed for mission #{mission.id}: #{Exception.message(e)}"
      )

      fail_quest(mission.id, "Validation fix attempt crashed")
  end

  # Build a comprehensive fix description from validation findings
  defp build_fix_description(_mission, validation, impl_files) do

    gaps = Map.get(validation, "gaps", [])

    unmet =
      (Map.get(validation, "requirements_met", []) || [])
      |> Enum.filter(fn r -> Map.get(r, "met") == false end)

    raw = Map.get(validation, "raw_output", "")
    summary = Map.get(validation, "summary", "")

    sections = ["## Validation Feedback\n"]

    sections =
      if unmet != [] do
        req_lines =
          Enum.map(unmet, fn req ->
            id = Map.get(req, "req_id", "?")
            evidence = Map.get(req, "evidence", "No details")
            files = extract_file_paths(evidence)
            file_hint = if files != [], do: " (#{Enum.join(files, ", ")})", else: ""
            "- **#{id}**: #{evidence}#{file_hint}"
          end)

        sections ++ ["### Unmet Requirements\n"] ++ req_lines ++ [""]
      else
        sections
      end

    sections =
      if gaps != [] do
        gap_lines = Enum.map(gaps, fn gap -> "- #{gap}" end)
        sections ++ ["### Gaps\n"] ++ gap_lines ++ [""]
      else
        sections
      end

    sections =
      if summary != "" do
        sections ++ ["### Summary\n", summary, ""]
      else
        sections
      end

    sections =
      if unmet == [] and gaps == [] and raw != "" do
        sections ++ ["### Raw Validator Output\n", String.slice(raw, 0, 2000), ""]
      else
        sections
      end

    sections =
      if impl_files != [] do
        sections ++ ["### Files Changed\n", Enum.join(impl_files, ", "), ""]
      else
        sections
      end

    instructions = """
    ## Instructions

    Your previous implementation was reviewed and the issues above were found.
    You are working in the SAME worktree with your previous changes still present.

    1. Review the feedback above carefully
    2. Read the specific files mentioned to understand what needs to change
    3. Make the minimal fixes needed to address each issue
    4. Verify your fixes are correct
    5. Commit your changes
    """

    Enum.join(sections, "\n") <> "\n" <> instructions
  end

  # Find a shell with an on-disk worktree from the mission's implementation ops
  defp find_implementation_shell(mission) do
    ghost_ids =
      mission.ops
      |> Enum.reject(& &1[:phase_job])
      |> Enum.map(& &1[:ghost_id])
      |> Enum.reject(&is_nil/1)

    # Prefer the most recent implementation ghost's shell
    ghost_ids
    |> Enum.reverse()
    |> Enum.find_value(fn ghost_id ->
      Archive.find_one(:shells, fn s ->
        s.ghost_id == ghost_id and
          s[:worktree_path] != nil and
          File.dir?(s.worktree_path)
      end)
    end)
  end

  # Spawn a fix ghost in an existing worktree so it inherits the implementation's code
  defp spawn_fix_in_worktree(fix_op, shell, mission) do
    case GiTF.gitf_dir() do
      {:ok, gitf_root} ->
        case GiTF.Ghosts.spawn_in_worktree(fix_op.id, shell.id, mission.sector_id, gitf_root) do
          {:ok, _ghost} -> :ok
          {:error, _} -> spawn_implementation_jobs(mission)
        end

      _ ->
        spawn_implementation_jobs(mission)
    end
  rescue
    _ -> spawn_implementation_jobs(mission)
  end

  defp load_mission_fix_context(mission) do
    case Map.get(mission, :fix_context) do
      nil ->
        max = max_fix_attempts_for(mission.sector_id)
        GiTF.Togusa.FixContext.new(mission.id, max_attempts: max)

      ctx_map ->
        GiTF.Togusa.FixContext.from_map(ctx_map) ||
          GiTF.Togusa.FixContext.new(mission.id, max_attempts: max_fix_attempts_for(mission.sector_id))
    end
  end

  defp store_mission_fix_context(mission_id, fix_ctx) do
    case Archive.get(:missions, mission_id) do
      nil -> :ok
      record -> Archive.put(:missions, Map.put(record, :fix_context, GiTF.Togusa.FixContext.to_map(fix_ctx)))
    end
  end

  defp learn_from_validation_failure(mission, validation) do
    # Find the most recent implementation op to attribute the failure to
    impl_op =
      (mission.ops || [])
      |> Enum.reject(& &1[:phase_job])
      |> Enum.max_by(& &1[:inserted_at], fn -> nil end)

    if impl_op do
      GiTF.Togusa.learn_from_failure(impl_op.id, validation)
    end
  rescue
    _ -> :ok
  end

  # Extract file paths from text (looks for common patterns like path/to/file.ext)
  defp extract_file_paths(text) when is_binary(text) do
    regex = ~r/(?:^|[\s`'"])([a-zA-Z][\w.\/-]*\.\w{1,6})(?:[\s`'",:\]]|$)/
    Regex.scan(regex, text)
    |> Enum.map(fn [_, path] -> path end)
    |> Enum.uniq()
  end

  defp extract_file_paths(_), do: []


  # -- Simplify Phase: 3 parallel agents (reuse, quality, efficiency) ----------

  defp start_simplify(mission) do
    with {:ok, _} <-
           GiTF.Missions.transition_phase(mission.id, "simplify", "Sync complete, simplifying") do
      sector = Archive.get(:sectors, mission.sector_id)
      repo_path = if sector, do: sector.path, else: nil

      # Get changed files from all implementation ops
      changed_files = get_mission_changed_files(mission)

      # Spawn 3 parallel review ghosts
      for {focus, prompt} <- PhasePrompts.simplify_prompts(mission, repo_path, changed_files) do
        spawn_phase_ghost(mission, "simplify", prompt, model: "general", strategy: focus)
      end

      {:ok, "simplify"}
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
            strategy = extract_strategy_from_title(op.title)
            artifact = GiTF.Missions.get_artifact(mission.id, "simplify_#{strategy}")
            %{focus: strategy, result: artifact}
          end)
          |> Enum.reject(&is_nil(&1.result))

        GiTF.Missions.store_artifact(mission.id, "simplify", %{
          "agents" => Enum.map(findings, & &1.focus),
          "completed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

        {:ok, mission} = GiTF.Missions.get(mission.id)
        start_scoring(mission)
      else
        {:ok, "simplify"}
      end
    end
  end

  defp get_mission_changed_files(mission) do
    mission.ops
    |> Enum.reject(& &1[:phase_job])
    |> Enum.flat_map(fn op ->
      case Map.get(op, :files_changed) || Map.get(op, :changed_files) do
        files when is_list(files) -> files
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  # -- Scoring Phase: final quality assessment --------------------------------

  defp start_scoring(mission) do
    with {:ok, _} <-
           GiTF.Missions.transition_phase(mission.id, "scoring", "Simplify complete, scoring") do
      requirements = GiTF.Missions.get_artifact(mission.id, "requirements")
      validation = GiTF.Missions.get_artifact(mission.id, "validation")
      ctx = GiTF.Intel.get_prompt_context(mission.sector_id, "scoring")
      prompt = PhasePrompts.scoring_prompt(mission, requirements, validation, ctx)
      spawn_phase_ghost(mission, "scoring", prompt, model: "general")
      {:ok, "scoring"}
    end
  end

  defp finish_scored(mission) do
    scoring = GiTF.Missions.get_artifact(mission.id, "scoring")

    if scoring do
      score = Map.get(scoring, "overall_score", 0)
      Logger.info("Quest #{mission.id} scored #{score}/100")
      record_triage_feedback(mission, score)
    end

    # Feed the learning loop — analyze each op's outcome
    ingest_mission_outcome(mission)

    complete_quest(mission.id)
  end

  # Store triage-vs-outcome data for future accuracy analysis.
  # Links the original triage complexity to the final quality score so
  # patterns like "ops triaged as simple but scored < 70" can be detected.
  defp record_triage_feedback(mission, score) do
    research = GiTF.Missions.get_artifact(mission.id, "research")
    triage_complexity = if research, do: Map.get(research, "complexity"), else: nil
    pipeline_mode = Map.get(mission, :pipeline_mode)

    Archive.insert(:triage_feedback, %{
      mission_id: mission.id,
      sector_id: mission.sector_id,
      triage_complexity: triage_complexity,
      pipeline_mode: pipeline_mode,
      quality_score: score,
      completed_at: DateTime.utc_now()
    })
  rescue
    e -> Logger.debug("Triage feedback recording failed: #{Exception.message(e)}")
  end

  # Analyze each non-phase op outcome and invalidate the sector profile.
  defp ingest_mission_outcome(mission) do
    Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
      mission.ops
      |> Enum.reject(& &1[:phase_job])
      |> Enum.each(fn op ->
        try do
          case op.status do
            "done" -> GiTF.Intel.analyze_success(op.id)
            "failed" -> GiTF.Intel.FailureAnalysis.analyze_failure(op.id)
            _ -> :ok
          end
        rescue
          _ -> :ok
        end
      end)

      GiTF.Intel.SectorProfile.invalidate(mission.sector_id)
    end)
  rescue
    _ -> :ok
  end

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
              _ -> :ok
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
      Logger.info("Quest #{mission_id} failed: rolling back sector at #{path}")
      GiTF.Git.rollback(path)
    else
      _ -> :ok
    end

    # Feed the learning loop — analyze failed ops
    ingest_failure_outcome(mission_id)

    GiTF.Missions.transition_phase(mission_id, "completed", reason)
    GiTF.Missions.update_status!(mission_id)

    GiTF.Observability.Alerts.dispatch_webhook(
      :quest_failed,
      "Quest #{mission_id} failed: #{reason}"
    )

    {:ok, "completed"}
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
          File.write!(Path.join(path, filename), content)
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

  defp do_complete_quest(mission) do
    GiTF.Telemetry.end_current_span()

    with {:ok, _} <-
           GiTF.Missions.transition_phase(mission.id, "completed", "All phases complete") do
      GiTF.Missions.update_status!(mission.id)

      GiTF.Observability.Alerts.dispatch_webhook(
        :quest_completed,
        "Quest #{mission.id} completed successfully"
      )

      if mission.sector_id && GiTF.Debrief.enabled?(mission.sector_id) do
        GiTF.Debrief.start_review(mission.id)
      end

      cleanup_mission_branch(mission)

      {:ok, "completed"}
    end
  end

  defp cleanup_mission_branch(mission) do
    mission_id = mission.id
    sector_id = mission.sector_id

    Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
      try do
        with sync_art when is_map(sync_art) <- GiTF.Missions.get_artifact(mission_id, "sync"),
             branch when is_binary(branch) <- sync_art["branch"],
             {:ok, sector} <- GiTF.Sector.get(sector_id) do
          GiTF.Git.branch_delete(sector.path, branch)
          GiTF.Git.safe_cmd(["push", "origin", "--delete", branch], cd: sector.path, stderr_to_stdout: true)
          Logger.info("Cleaned up mission branch #{branch}")
        end
      rescue
        e ->
          Logger.warning("Failed to cleanup mission branch for #{mission_id}: #{Exception.message(e)}")
      end
    end)
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

    # Build title with strategy label for parallel planning ghosts
    title =
      if strategy do
        "#{String.capitalize(phase)} [#{strategy}] for: #{String.slice(mission.goal, 0, 50)}"
      else
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
      assigned_model: model_id(model)
    }

    with {:ok, op} <- GiTF.Ops.create(job_attrs),
         _ = GiTF.Missions.record_phase_job(mission.id, phase, op.id),
         {:ok, gitf_root} <- GiTF.gitf_dir(),
         {:ok, ghost} <-
           GiTF.Ghosts.spawn_detached(op.id, mission.sector_id, gitf_root, prompt: prompt) do
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

  # Returns the max redesign iterations, consulting sector intelligence at :high confidence.
  defp max_redesign_for(nil), do: @default_max_redesign

  defp max_redesign_for(sector_id) do
    profile = GiTF.Intel.SectorProfile.get_or_compute(sector_id)

    case profile do
      %{confidence: :high, recommendations: %{max_redesign_iterations: n}} -> n
      _ -> @default_max_redesign
    end
  rescue
    _ -> @default_max_redesign
  end

  # Returns the max validation fix attempts, consulting sector intelligence at :high confidence.
  defp max_fix_attempts_for(nil), do: @default_max_fix_attempts

  defp max_fix_attempts_for(sector_id) do
    profile = GiTF.Intel.SectorProfile.get_or_compute(sector_id)

    case profile do
      %{confidence: :high, recommendations: %{max_validation_fix_attempts: n}} -> n
      _ -> @default_max_fix_attempts
    end
  rescue
    _ -> @default_max_fix_attempts
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

  # Delegates to Major's priority-aware scheduler instead of bypassing it.
  # The scheduler will pick up pending implementation ops in priority order,
  # respecting ghost slot limits and budget checks.
  defp spawn_implementation_jobs(_mission) do
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
          # Last resort: single op from mission goal
          [
            %{
              "title" => "Implement: #{String.slice(mission.goal, 0, 80)}",
              "description" => mission.goal,
              "op_type" => "implementation"
            }
          ]
      end

    if specs != [] do
      Logger.info("Quest #{mission.id}: generated #{length(specs)} synthetic ops from artifacts")
      Planner.create_jobs_from_specs(mission.id, specs)
    end

    {:ok, specs}
  rescue
    e ->
      Logger.warning(
        "Synthetic op generation failed for mission #{mission.id}: #{Exception.message(e)}"
      )

      {:ok, []}
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
      Logger.warning(
        "Budget preflight check failed for #{mission_id}: #{Exception.message(e)}, allowing"
      )

      :ok
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
        case GiTF.Archive.get(:missions, mission.id) do
          nil ->
            {:error, :no_sector_assigned}

          record ->
            GiTF.Archive.put(:missions, Map.put(record, :sector_id, single.id))
            Logger.info("Auto-assigned sector #{single.name} to mission #{mission.id}")
            :ok
        end

      _multiple ->
        # Multiple sectors — try to use the current default
        case GiTF.Sector.current() do
          {:ok, current} ->
            case GiTF.Archive.get(:missions, mission.id) do
              nil ->
                {:error, :no_sector_assigned}

              record ->
                GiTF.Archive.put(:missions, Map.put(record, :sector_id, current.id))

                Logger.info(
                  "Auto-assigned current sector #{current.name} to mission #{mission.id}"
                )

                :ok
            end

          _ ->
            {:error, :no_sector_assigned}
        end
    end
  end

  defp approval_timeout_hours, do: Config.get([:approvals, :timeout_hours], 1)
  defp max_quest_age_hours, do: Config.get([:major, :mission_timeout_hours], 24)

  # Determine the highest-risk op type in a mission (for auto-approve gating)
  defp mission_max_risk(mission_id) do
    case GiTF.Archive.get(:missions, mission_id) do
      nil ->
        :normal

      mission ->
        ops = Map.get(mission, :ops, [])

        cond do
          Enum.any?(ops, fn op -> Map.get(op, :risk_level) == :critical end) -> :critical
          Enum.any?(ops, fn op -> Map.get(op, :risk_level) == :high end) -> :high
          true -> :normal
        end
    end
  end

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
    Map.get(artifact, "parse_failed", false) == true
  end

  defp artifact_failed?(_), do: false

  defp fetch_sector(sector_id) do
    case Archive.get(:sectors, sector_id) do
      nil -> {:error, :sector_not_found}
      sector -> {:ok, sector}
    end
  end
end
