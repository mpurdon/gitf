defmodule GiTF.Major.PhaseLauncher do
  @moduledoc """
  THE PHASE LAUNCHER — the persona that puts a ghost in the field. For
  every leg of the journey it does the same three things: transition the
  mission's phase, build that phase's prompt out of the artifacts the
  earlier legs produced, and spawn the ghost that will produce the next
  artifact.

  It is deliberately the ONLY place a phase ghost is born. The
  Orchestrator decides *whether* to move; the launcher knows *how* each
  phase is started, which is why `dispatch_phase/2`, the workflow
  bridge, and the stuck-phase re-spawn all funnel back through here
  rather than each rolling their own spawn.

  The incidents that shaped it:

    * DOUBLE-SPAWN. `spawn_phase_ghost/4` refuses to create a second op
      for a phase (and strategy) that already has one pending/running —
      retry loops were spawning 100+ ops. Validation carries a stricter
      version of the same rule: it short-circuits only on an IN-FLIGHT
      validation, never on a completed one. Guarding on "any validation
      op ever existed" wedged the fix loop — the mission stayed in
      `implementation` forever and never re-validated to detect
      exhaustion.
    * msn-dd29a1. A mission amending an open pull request must WORK ON
      that branch, not merely merge into it later. `target_branch` was
      applied only in `Sync.merge_quest`, so every ghost was cut from
      main: the file under review did not exist in any ghost's worktree,
      the correct commit fell out of a union merge rather than a ghost
      editing it, and validation then diffed a tree without the change
      and reported the work missing. Defaulting the base branch here
      covers every phase in one place.
    * msn-7683ac. Validation is never spawned onto a marker-laden tree —
      that is how four fix attempts were burned. Consolidation stops at
      the first conflicted merge and `Endgame` reconciles that ONE merge;
      only when the endgame's caps are exhausted does validation proceed,
      carrying the disputed file list so ground truth can adjudicate.
    * Orphaned simplify commits. Simplify worktrees branch from the quest
      branch that sync just merged into, not sector HEAD, so cleanup
      commits are picked up by publish's push/PR.
    * Fast-model navigation. A trivial-triaged impl ghost handed only the
      raw mission goal has to search the repo blindly, which fast models
      handle poorly (they loop on Read/Grep). Triage's target_files,
      goal restatement and external context are folded into the op
      description instead.
  """

  require Logger

  alias GiTF.Archive
  alias GiTF.Major.{DesignBoard, Endgame, FastPath, GroundTruth}
  alias GiTF.Major.{ModelPolicy, Orchestrator, PhasePrompts, Planner, Topology}
  alias GiTF.Major.Orchestrator.Decisions

  @default_phase_timeout_seconds 900

  @doc """
  Maps a phase id to the function that starts it. The Orchestrator's
  `dispatch_phase/2` and the workflow bridge both drive phase
  advancement through this map.
  """
  def phase_starters do
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

  # -- Triage: is there even work here? ----------------------------------------

  @doc false
  def start_triage(mission) do
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

  @doc """
  Routes a triaged mission to the first phase its skip flags did not
  skip. Complexity can legitimately skip straight to implementation.
  """
  def route_to_first_unskipped_phase(mission, skip_flags) do
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

  # -- Research and requirements: understand before designing ------------------

  @doc false
  def start_research(mission) do
    sector_id = Map.get(mission, :sector_id)

    if is_nil(sector_id) do
      {:error, :no_sector_assigned}
    else
      with {:ok, _} <- GiTF.Missions.transition_phase(mission.id, "research") do
        sector = Archive.get(:sectors, sector_id)
        ctx = GiTF.Intel.get_prompt_context(sector_id, "research", mission)

        prompt =
          PhasePrompts.research_prompt(mission, sector, ctx,
            complexity: GiTF.Triage.mission_complexity(mission)
          )

        spawn_phase_ghost(mission, "research", prompt, model: "general")
        {:ok, "research"}
      end
    end
  end

  @doc false
  def start_requirements(mission) do
    research = GiTF.Missions.get_artifact(mission.id, "research")

    with {:ok, _} <-
           GiTF.Missions.transition_phase(mission.id, "requirements") do
      ctx = GiTF.Intel.get_prompt_context(mission.sector_id, "requirements", mission)
      prompt = PhasePrompts.requirements_prompt(mission, research, ctx)
      spawn_phase_ghost(mission, "requirements", prompt, model: "general")
      {:ok, "requirements"}
    end
  end

  # -- Design and review: the tournament ---------------------------------------

  @doc false
  def start_design(mission) do
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
          DesignBoard.strategies_for_complexity(research, mission.sector_id)
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
          model: ModelPolicy.phase_model_for_complexity("design", mission),
          strategy: strategy_name
        )
      end)

      {:ok, "design"}
    end
  end

  @doc false
  def start_review(mission) do
    requirements = GiTF.Missions.get_artifact(mission.id, "requirements")
    research = GiTF.Missions.get_artifact(mission.id, "research")

    # Collect all design variants (design_minimal, design_normal, design_complex)
    designs = DesignBoard.collect_design_variants(mission.id)

    with {:ok, _} <- GiTF.Missions.transition_phase(mission.id, "review") do
      prompt = PhasePrompts.review_prompt(mission, designs, requirements, research)

      spawn_phase_ghost(mission, "review", prompt,
        model: ModelPolicy.phase_model_for_complexity("review", mission)
      )

      {:ok, "review"}
    end
  end

  # -- Planning: turn the chosen design into ops -------------------------------

  @doc false
  def start_planning(mission) do
    design = GiTF.Missions.get_artifact(mission.id, "design")
    requirements = GiTF.Missions.get_artifact(mission.id, "requirements")
    review = GiTF.Missions.get_artifact(mission.id, "review")

    with {:ok, _} <- GiTF.Missions.transition_phase(mission.id, "planning") do
      ctx = GiTF.Intel.get_prompt_context(mission.sector_id, "planning", mission)
      prompt = PhasePrompts.planning_prompt(mission, design, requirements, review, ctx)

      spawn_phase_ghost(mission, "planning", prompt,
        model: ModelPolicy.phase_model_for_complexity("planning", mission)
      )

      {:ok, "planning"}
    end
  end

  # -- Implementation: the ops do the work -------------------------------------

  @doc false
  def start_implementation(mission) do
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
      Orchestrator.spawn_implementation_jobs(mission)

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
    if Orchestrator.impl_ops_exist?(mission.id) do
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

  # -- Validation: consolidate, then judge -------------------------------------

  @doc false
  def start_validation(mission) do
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

  @doc """
  True when a validation-phase op for `mission_id` is pending, assigned or
  running.

  One owner for the question, because two callers ask it for opposite
  reasons: the launcher asks "may I spawn?" and
  `GiTF.Phases.Validation` asks "is anyone still coming?" before deciding
  a phase with no artifact is stranded. Two definitions that drifted apart
  would either double-spawn or wait forever.
  """
  @spec validation_in_flight?(String.t()) :: boolean()
  def validation_in_flight?(mission_id) do
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
      diff_base = Topology.detect_diff_base(mission)

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
          case Topology.consolidate_impl_branches(mission, Map.get(ops_by_variant, nil, [])) do
            {:conflict_pending, branch, files} ->
              # Do NOT spawn a validation ghost onto a marker-laden tree —
              # that is how msn-7683ac burned all four fix attempts. A
              # focused resolution op reconciles this ONE merge, then the
              # mission re-enters validation and consolidation resumes.
              case Endgame.start_conflict_resolution(mission, branch, files) do
                {:cap_exhausted, marked} ->
                  changed_files = collect_changed_files(ops_by_variant, nil)

                  notes = [
                    "POSSIBLE unresolved conflict markers in: #{Enum.join(marked, ", ")} — " <>
                      "the marker scan flags these but two focused resolution ghosts " <>
                      "reported them clean. Verify against the actual file content; " <>
                      "reconcile only if real."
                  ]

                  spawn_validation_for_variant(
                    mission,
                    requirements,
                    planning,
                    ctx,
                    diff_base,
                    nil,
                    changed_files,
                    notes
                  )

                  {:ok, "validation"}

                other ->
                  other
              end

            {:ok, notes} ->
              changed_files = collect_changed_files(ops_by_variant, nil)

              spawn_validation_for_variant(
                mission,
                requirements,
                planning,
                ctx,
                diff_base,
                nil,
                changed_files,
                notes
              )

              {:ok, "validation"}
          end

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

          {:ok, "validation"}
      end
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
    lsp_diagnostics =
      without_aborting([], fn ->
        collect_lsp_diagnostics_for_validation(mission, changed_files)
      end)

    {exec_validation, infra_notes} = exec_validation_or_note(mission, variant_id)

    # Main can move under a mission that takes an hour. The fix loop was
    # reconciling other people's merged work without ever being told what
    # that work was — and when the merge was clean, nothing signalled that
    # the plan might have been overtaken at all.
    base_moved =
      without_aborting(nil, fn ->
        case GiTF.Validation.canonical_impl_shell(mission) do
          %{worktree_path: wt} -> GiTF.Drift.main_advance_summary(wt)
          _ -> nil
        end
      end)

    prompt =
      PhasePrompts.validation_prompt(mission, requirements, planning, ctx,
        diff_base: diff_base,
        changed_files: changed_files,
        lsp_diagnostics: lsp_diagnostics,
        exec_validation: exec_validation,
        infra_notes: infra_notes,
        accepted_requirements: Map.get(mission, :accepted_requirements) || [],
        contested_requirements: open_contested_requirements(mission),
        merge_conflicts: merge_conflicts,
        base_moved: base_moved,
        unresolved_review: GiTF.Phases.Review.unresolved_objection(mission)
      )

    # Branch the validation worktree from the variant's impl ghost tip so
    # `git diff` against the sector main shows that variant's changes only.
    base_opts =
      case Topology.variant_base_branch(mission, variant_id) do
        nil -> Topology.impl_base_branch_opts(mission)
        base -> [base_branch: base]
      end

    opts = [model: "general"] ++ base_opts ++ if variant_id, do: [variant: variant_id], else: []
    spawn_phase_ghost(mission, "validation", prompt, opts)
  end

  # The contested set minus whatever has since been accepted. The two
  # registers are opposed, and an id on both was rebutted at some point —
  # `Phases.Validation.enforce_contested_rebuttals/1` is the only door
  # through which a contested id reaches `accepted_requirements`. Quoting
  # a settled verdict back at the validator would re-open work the
  # factory has already banked, which is exactly what the ratchet exists
  # to prevent.
  defp open_contested_requirements(mission) do
    accepted = MapSet.new(Map.get(mission, :accepted_requirements) || [])

    (Map.get(mission, :contested_requirements) || [])
    |> Enum.filter(fn entry ->
      is_map(entry) and is_binary(entry["req_id"]) and
        not MapSet.member?(accepted, entry["req_id"])
    end)
  end

  # -- Nothing gathered for the prompt may abort the spawn ---------------------

  # msn-05bebd: `do_start_validation/3` transitions the mission to
  # `validation` and only THEN gathers the prompt's inputs. Everything in
  # that window is best-effort context — but the exec validation in the
  # middle of it shells out, and when it died it took the calling process
  # with it. The mission was left at `phase = validation` with no
  # validation op in existence, which `Phases.Validation.verdict/2` reads
  # as "no artifact yet" and answers `:wait` — forever. The window is now
  # closed at both ends: nothing here can abort the spawn (this half), and
  # the verdict self-heals if a spawn is somehow still missing (the other
  # half, in `GiTF.Phases.Validation`).
  defp without_aborting(default, fun) do
    fun.()
  rescue
    e ->
      Logger.warning("Validation prompt input failed (non-fatal): #{Exception.message(e)}")
      default
  catch
    kind, reason ->
      Logger.warning("Validation prompt input #{kind}ed (non-fatal): #{inspect(reason)}")
      default
  end

  # The exec validation gets stronger isolation than `without_aborting/2`
  # because its failure mode is not an exception. `GiTF.Validator`'s
  # command runner spawns a LINKED `Task`; an `:enoent` raised inside it by
  # `System.cmd` (missing sandbox binary, a resume-seeded worktree path
  # that no longer exists) reaches this process as an exit signal, which no
  # `rescue` in `GroundTruth` or `Validator` can see. `async_nolink` breaks
  # the link, so the failure comes back as a value.
  #
  # Returns `{verdict, notes}`. An unreachable ground truth is still
  # recorded as an INFRA verdict, so the downstream guard holds the fix
  # budget instead of spending an attempt on code that was never judged.
  @doc false
  def exec_validation_or_note(mission, variant_id) do
    timeout = exec_validation_timeout_ms(mission)

    task =
      Task.Supervisor.async_nolink(GiTF.TaskSupervisor, fn ->
        GroundTruth.run_exec_validation(mission, variant_id)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, 5_000) do
      {:ok, verdict} ->
        {verdict, []}

      {:exit, reason} ->
        abort_note(mission, "the validation command runner crashed: #{inspect(reason)}")

      nil ->
        abort_note(
          mission,
          "the validation command did not return within #{div(timeout, 1000)}s and was killed"
        )
    end
  end

  defp abort_note(mission, why) do
    Logger.error(
      "Quest #{mission.id}: exec validation aborted — #{why}; spawning validation anyway"
    )

    GiTF.Telemetry.emit([:gitf, :validation, :exec_aborted], %{}, %{
      mission_id: mission.id,
      reason: why
    })

    GroundTruth.store_infra_verdict(mission, "TOOL MISSING on host — #{why}")

    {nil, ["Ground truth was UNAVAILABLE this round: #{why}."]}
  end

  # The runner already enforces the sector's own deadline; this is the
  # outer backstop for a runner that never returns at all, so it is the
  # sector budget plus slack rather than a competing limit.
  defp exec_validation_timeout_ms(mission) do
    sector =
      case Map.get(mission, :sector_id) do
        id when is_binary(id) -> Archive.get(:sectors, id)
        _ -> nil
      end

    GiTF.Validator.validation_timeout_ms(sector) + :timer.seconds(60)
  end

  # -- Simplify and scoring: the tail ------------------------------------------

  @doc false
  def start_simplify(mission) do
    if Decisions.simplify_skippable?(GiTF.Triage.mission_complexity(mission)) do
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
        opts = [model: "general"] ++ Topology.quest_branch_base_opts(mission)

        for {focus, prompt} <- PhasePrompts.simplify_prompts(mission, repo_path, changed_files) do
          spawn_phase_ghost(mission, "simplify", prompt, opts ++ [strategy: focus])
        end

        {:ok, "simplify"}
      end
    end
  end

  @doc false
  def start_scoring(mission) do
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

  # -- Ghost spawning ----------------------------------------------------------

  @doc """
  Creates a phase op and spawns its ghost, refusing to duplicate a phase
  (and strategy) that already has one pending/running.
  """
  def spawn_phase_ghost(mission, phase, prompt, opts) do
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
    model = ModelPolicy.pick_model_for_phase(mission.sector_id, phase, default_model)

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
      assigned_model: ModelPolicy.model_id(model)
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
      |> Keyword.merge(Topology.mission_base_branch_opts(mission))
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

  # -- Re-spawn support --------------------------------------------------------

  # Returns the phase timeout in seconds, consulting sector intelligence.
  @doc false
  def phase_timeout_for(nil, _phase), do: @default_phase_timeout_seconds

  def phase_timeout_for(sector_id, phase) do
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

  # Rebuild the real prompt for a phase re-spawn using available artifacts
  @doc false
  def rebuild_phase_prompt(mission, phase) do
    sector = if mission.sector_id, do: Archive.get(:sectors, mission.sector_id)
    ctx = GiTF.Intel.get_prompt_context(mission.sector_id, phase, mission)

    case phase do
      "research" ->
        {PhasePrompts.research_prompt(mission, sector, ctx,
           complexity: GiTF.Triage.mission_complexity(mission)
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
            diff_base: Topology.detect_diff_base(mission),
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

  # -- Artifact reporting ------------------------------------------------------

  @doc false
  def summarize_artifacts(artifacts) when map_size(artifacts) == 0, do: %{}

  def summarize_artifacts(artifacts) do
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
end
