defmodule GiTF.Major.Planner do
  @moduledoc """
  Major's planning capabilities for Phase 2.3.

  Takes research summary and generates structured implementation plans
  with ops, verification criteria, and context estimates.
  """

  alias GiTF.Archive
  alias GiTF.Ops.Classifier

  @doc """
  Generate implementation plan from research summary.

  Creates structured plan with ops, dependencies, and verification criteria.
  Focuses on MINIMAL implementation to achieve stated goal.
  """
  @spec generate_plan(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def generate_plan(mission_id, research_summary) do
    with {:ok, mission} <- GiTF.Missions.get(mission_id),
         {:ok, plan} <- create_implementation_plan(mission, research_summary) do
      # Add acceptance criteria and scope boundaries
      enhanced_plan =
        Map.merge(plan, %{
          acceptance_criteria: define_acceptance_criteria(mission),
          scope_boundaries: define_scope_boundaries(mission),
          simplicity_target: calculate_simplicity_target(plan)
        })

      # Archive plan in mission
      quest_record = Archive.get(:missions, mission_id)
      updated = Map.put(quest_record, :implementation_plan, enhanced_plan)
      Archive.put(:missions, updated)

      {:ok, enhanced_plan}
    end
  end

  @doc """
  Create ops from implementation plan.

  Converts plan structure into actual op records with dependencies.
  """
  @spec create_jobs_from_plan(String.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def create_jobs_from_plan(mission_id, plan) do
    with {:ok, mission} <- GiTF.Missions.get(mission_id) do
      ops =
        plan.tasks
        |> Enum.with_index()
        |> Enum.map(fn {task, index} ->
          create_job_from_task(mission_id, mission.sector_id, task, index)
        end)

      # Create op records
      created_jobs =
        Enum.map(ops, fn job_attrs ->
          {:ok, op} = GiTF.Ops.create(job_attrs)
          op
        end)

      # Add dependencies
      add_job_dependencies(created_jobs, plan.dependencies)

      {:ok, created_jobs}
    end
  end

  # Private helpers

  defp create_implementation_plan(mission, research_summary) do
    # Basic plan structure - would be enhanced with model-based planning
    plan = %{
      mission_id: mission.id,
      goal: mission.goal,
      research_input: research_summary,
      tasks: generate_basic_tasks(mission, research_summary),
      dependencies: [],
      verification_strategy: "automated_testing",
      estimated_duration: "2-4 hours",
      created_at: DateTime.utc_now()
    }

    {:ok, plan}
  end

  defp generate_basic_tasks(mission, research_summary) do
    # Generate basic task structure based on mission goal and research
    main_language = research_summary[:structure][:main_language] || "unknown"

    base_tasks = [
      %{
        title: "Setup and preparation",
        description: "Initialize project structure and dependencies",
        type: :setup,
        complexity: :simple,
        estimated_tokens: 5000,
        verification_criteria: ["Project builds successfully", "Dependencies installed"]
      },
      %{
        title: "Core implementation",
        description: "Implement main functionality for: #{mission.goal}",
        type: :implementation,
        complexity: :moderate,
        estimated_tokens: 15000,
        verification_criteria: ["Core functionality works", "Basic tests pass"]
      }
    ]

    # Add language-specific tasks
    language_tasks =
      case main_language do
        "elixir" ->
          [
            %{
              title: "Add tests",
              description: "Write comprehensive ExUnit tests",
              type: :audit,
              complexity: :simple,
              estimated_tokens: 8000,
              verification_criteria: ["All tests pass", "Coverage > 80%"]
            }
          ]

        "javascript" ->
          [
            %{
              title: "Add tests",
              description: "Write Jest/Mocha tests",
              type: :audit,
              complexity: :simple,
              estimated_tokens: 8000,
              verification_criteria: ["All tests pass", "Coverage > 80%"]
            }
          ]

        _ ->
          [
            %{
              title: "Add validation",
              description: "Add basic validation and error handling",
              type: :audit,
              complexity: :simple,
              estimated_tokens: 5000,
              verification_criteria: ["Error handling works", "Input validation"]
            }
          ]
      end

    base_tasks ++ language_tasks
  end

  defp create_job_from_task(mission_id, sector_id, task, _index) do
    classification = Classifier.classify_and_recommend(task.title, task.description)

    %{
      title: task.title,
      description: task.description,
      mission_id: mission_id,
      sector_id: sector_id,
      op_type: classification.op_type,
      complexity: classification.complexity,
      recommended_model: classification.recommended_model,
      verification_criteria: task.verification_criteria,
      estimated_context_tokens: task.estimated_tokens
    }
  end

  defp add_job_dependencies(ops, dependencies) do
    # Add dependencies based on task order (sequential by default)
    ops
    |> Enum.with_index()
    |> Enum.each(fn {op, index} ->
      if index > 0 do
        prev_job = Enum.at(ops, index - 1)
        GiTF.Ops.add_dependency(op.id, prev_job.id)
      end
    end)

    # Add any custom dependencies from plan
    Enum.each(dependencies, fn {from_idx, to_idx} ->
      from_job = Enum.at(ops, from_idx)
      to_job = Enum.at(ops, to_idx)

      if from_job && to_job do
        GiTF.Ops.add_dependency(to_job.id, from_job.id)
      end
    end)
  end

  @doc """
  Generate an LLM-driven plan for a mission.

  Loads existing artifacts (research, requirements, design, review) and builds
  a prompt for the LLM. Returns a plan structure with tasks but does NOT create
  op records — that happens on confirmation.
  """
  @spec generate_llm_plan(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def generate_llm_plan(mission_id, opts \\ %{}) do
    with {:ok, mission} <- GiTF.Missions.get(mission_id) do
      # Gather existing artifacts
      research = GiTF.Missions.get_artifact(mission_id, "research")
      requirements = GiTF.Missions.get_artifact(mission_id, "requirements")
      design = GiTF.Missions.get_artifact(mission_id, "design")
      review = GiTF.Missions.get_artifact(mission_id, "review")

      prompt = build_llm_plan_prompt(mission, research, requirements, design, review, opts)

      case GiTF.Runtime.Models.generate_text(prompt, model: "thinking") do
        {:ok, response} ->
          text = extract_text(response)

          case parse_plan_json(text) do
            {:ok, tasks} ->
              plan = %{
                mission_id: mission_id,
                goal: mission.goal,
                tasks: tasks,
                estimated_duration: estimate_duration(tasks),
                created_at: DateTime.utc_now()
              }

              # Archive as draft on the mission
              quest_record = Archive.get(:missions, mission_id)

              if quest_record do
                updated = Map.put(quest_record, :draft_plan, plan)
                Archive.put(:missions, updated)
              end

              {:ok, plan}

            {:error, :parse_failed} ->
              # Fallback: return raw text as a single-task plan
              {:ok,
               %{
                 mission_id: mission_id,
                 goal: mission.goal,
                 tasks: [
                   %{
                     "title" => "Implementation",
                     "description" => text,
                     "target_files" => [],
                     "model_recommendation" => "general"
                   }
                 ],
                 estimated_duration: "unknown",
                 created_at: DateTime.utc_now()
               }}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_llm_plan_prompt(mission, research, requirements, design, review, opts) do
    feedback = Map.get(opts, :feedback)
    strategy = Map.get(opts, :strategy)
    strategy_hint = Map.get(opts, :strategy_hint)

    strategy_section = strategy_instruction(strategy, strategy_hint)

    cond do
      # Full artifacts available — use the detailed planning prompt
      design && requirements && review ->
        base = GiTF.Major.PhasePrompts.planning_prompt(mission, design, requirements, review)
        if strategy_section == "", do: base, else: base <> "\n" <> strategy_section <> "\n"

      # Some artifacts — build a simpler prompt with what we have
      true ->
        sector_path =
          if mission[:sector_id] do
            case GiTF.Sector.get(mission.sector_id) do
              {:ok, sector} -> sector[:path] || "unknown"
              _ -> "unknown"
            end
          else
            "unknown"
          end

        artifacts_section =
          [
            if(research,
              do: "## Research\n```json\n#{Jason.encode!(research, pretty: true)}\n```"
            ),
            if(requirements,
              do: "## Requirements\n```json\n#{Jason.encode!(requirements, pretty: true)}\n```"
            ),
            if(design, do: "## Design\n```json\n#{Jason.encode!(design, pretty: true)}\n```"),
            if(review, do: "## Review\n```json\n#{Jason.encode!(review, pretty: true)}\n```")
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n\n")

        feedback_section = if feedback, do: "\n## Revision Feedback\n#{feedback}\n", else: ""

        """
        # Planning Phase

        You are a project planner. Produce an ordered list of implementation ops.

        **Goal**: #{mission.goal}
        **Project path**: #{sector_path}

        #{artifacts_section}
        #{feedback_section}
        #{strategy_section}

        ## Instructions

        1. Break the work into discrete, parallelizable ops
        2. Each op should be completable by a single developer in one session
        3. Define clear acceptance criteria
        4. Specify target files where possible
        5. Set up dependencies (op indices, 0-based)
        6. Recommend model complexity (general for simple, thinking for complex)

        ## Output Format

        Output ONLY a JSON array in a ```json fence:

        ```json
        [
          {
            "title": "Short descriptive title",
            "description": "Detailed implementation instructions",
            "target_files": ["path/to/file"],
            "acceptance_criteria": ["Testable criterion 1"],
            "depends_on_indices": [],
            "model_recommendation": "general"
          }
        ]
        ```

        Split ops by file ownership: two ops must NOT both list the same file in
        target_files unless one depends_on the other (parallel ghosts editing the
        same file produce merge conflicts), and ops with disjoint target_files and
        no data dependency must NOT depend on each other (artificial serialization
        wastes wall-clock). Size each op for one ghost in one session.
        """
    end
  end

  @doc false
  def strategy_instruction(nil, _), do: ""

  def strategy_instruction("minimal", _hint) do
    """
    ## Strategy: MINIMAL
    Go for the simplest thing that works. Fewest files changed, no new abstractions,
    no tests unless they already exist. Skip nice-to-haves. If something can be
    hardcoded instead of configurable, hardcode it. One op if possible.
    """
  end

  def strategy_instruction("normal", _hint) do
    """
    ## Strategy: NORMAL
    Standard implementation with reasonable completeness. Follow existing patterns
    in the codebase. Include tests if the project has a test suite. Handle obvious
    edge cases but don't over-engineer. 2-3 ops is typical.
    """
  end

  def strategy_instruction("complex", _hint) do
    """
    ## Strategy: COMPLEX
    Comprehensive implementation with thorough coverage. Add tests, handle edge
    cases, consider error states, and document non-obvious decisions. If the design
    mentions optional enhancements, include them. 3-4 ops is typical.
    """
  end

  def strategy_instruction(name, hint) when is_binary(hint) do
    "## Strategy: #{String.upcase(name)}\n#{hint}. Design the plan accordingly.\n"
  end

  def strategy_instruction(_, _), do: ""

  defp extract_text(%{text: text}), do: text
  defp extract_text(text) when is_binary(text), do: text
  defp extract_text(other), do: inspect(other)

  defp parse_plan_json(text) do
    # Try to extract JSON from ```json ... ``` fence first
    json_str =
      case Regex.run(~r/```json\s*\n(.*?)\n\s*```/s, text) do
        [_, json] -> json
        _ -> text
      end

    case Jason.decode(json_str) do
      {:ok, tasks} when is_list(tasks) -> {:ok, tasks}
      _ -> {:error, :parse_failed}
    end
  end

  defp estimate_duration(tasks) do
    count = length(tasks)

    cond do
      count <= 2 -> "30-60 minutes"
      count <= 5 -> "1-2 hours"
      count <= 10 -> "2-4 hours"
      true -> "4+ hours"
    end
  end

  @doc """
  Creates implementation ops from phase-generated specs.

  Takes a list of op spec maps (from the planning phase ghost output) and
  creates real op records with dependencies.

  Returns `{:ok, [op]}`.

  ## Options

    * `:variant` — tournament variant id (e.g., `"v1"`). When set, every
      created op carries the variant tag so the validator and the
      branch-merge step can tell variants apart. The op title is also
      prefixed `[<variant>]` for log readability.
  """
  @spec create_jobs_from_specs(String.t(), [map()], keyword()) :: {:ok, [map()]}
  def create_jobs_from_specs(mission_id, job_specs, opts \\ []) do
    mission = Archive.get(:missions, mission_id)
    sector_id = if mission, do: mission.sector_id
    variant = Keyword.get(opts, :variant)

    # Structural enforcement of the ownership-split doctrine: the planning
    # prompt states the rules, but the LLM's output is a suggestion —
    # enforcement is the guarantee. Two layers:
    #
    #   * trivial/simple missions (or plans whose whole footprint fits a
    #     couple of files) still collapse to ONE op — splitting one-session
    #     work adds handoffs without capability, the run-13→18 lesson.
    #   * everything else keeps its ops, but any two that touch the SAME
    #     file without a dependency path between them get serialized by an
    #     added dependency. That targets the actual hazard — parallel
    #     ghosts editing one file wrote the conflict markers that killed
    #     msn-8e0eae — without flattening the parallelism of disjoint
    #     surfaces, which merges trivially.
    job_specs =
      cond do
        mission != nil and variant == nil and length(job_specs) > 1 and
            single_agent_scope?(mission, job_specs) ->
          require Logger

          Logger.info(
            "Planner: merging #{length(job_specs)} op specs into ONE for " <>
              "single-agent-scope mission #{mission_id}"
          )

          [merge_specs_into_one(mission, job_specs)]

        length(job_specs) > 1 ->
          serialize_shared_files(job_specs)

        true ->
          job_specs
      end

    {ops, _id_map} =
      job_specs
      |> Enum.with_index()
      |> Enum.reduce({[], %{}}, fn {spec, idx}, {acc, id_map} ->
        # Implementation ops always route to `"thinking"` per
        # `ModelSelector.select_model_for_job/2`. Planning's LLM output
        # defaults `model_recommendation` to `"general"` (flash), which
        # triggers the known flash-loops-on-impl failure mode. The
        # ModelSelector policy is the source of truth; planning's
        # suggestion is only honored when it escalates above the policy
        # default.
        base_title = spec["title"] || "Job #{idx + 1}"
        title = if variant, do: "[#{variant}] #{base_title}", else: base_title

        job_attrs = %{
          title: title,
          description: spec["description"],
          mission_id: mission_id,
          sector_id: sector_id,
          acceptance_criteria: spec["acceptance_criteria"] || [],
          target_files: spec["target_files"] || [],
          phase_job: false,
          variant: variant,
          assigned_model: impl_op_model(spec["model_recommendation"]),
          verification_contract: spec["verification_contract"]
        }

        case GiTF.Ops.create(job_attrs) do
          {:ok, op} ->
            # Resolve dependencies by index — PLUS an implicit dependency on
            # the previous op, serializing a mission's implementation chain.
            # Parallel impl ops editing overlapping files (four ops all
            # touching models.rs in msn-269675) each implemented their own
            # version blind to the siblings; branch consolidation then
            # unioned three divergent designs into duplicate-riddled,
            # uncompilable code (finding #18). Sequential ops build on the
            # actual prior work. Intra-mission parallelism returns when
            # file-ownership partitioning exists; cross-mission parallelism
            # is unaffected.
            deps = spec["depends_on_indices"] || []
            deps = if idx > 0, do: Enum.uniq([idx - 1 | deps]), else: deps

            for dep_idx <- deps do
              case Map.get(id_map, dep_idx) do
                nil -> :ok
                dep_id -> GiTF.Ops.add_dependency(op.id, dep_id)
              end
            end

            {[op | acc], Map.put(id_map, idx, op.id)}

          {:error, reason} ->
            require Logger
            Logger.warning("Failed to create op from spec #{idx}: #{inspect(reason)}")
            {acc, id_map}
        end
      end)

    ops = Enum.reverse(ops)
    add_file_overlap_dependencies(ops)
    {:ok, ops}
  end

  # Triage's complexity label varies run to run for the same goal (run 18:
  # fast-path; run 19: "complex" — identical mission text), so the label
  # alone can't gate single-op mode. The plan's own footprint is the
  # honest measure: a feature whose specs touch ≤ this many distinct files
  # fits one agent's session regardless of what triage called it.
  # Was 10, which swallowed every plan for a small repo — cora's entire
  # feature surface is 1-3 files, so no cora mission could ever produce a
  # multi-op plan no matter what the planner emitted. Two files is the
  # honest bar for "one session, unconditionally".
  @single_agent_max_files 2

  defp single_agent_scope?(mission, job_specs) do
    distinct_files =
      job_specs
      |> Enum.flat_map(&(&1["target_files"] || []))
      |> Enum.uniq()
      |> length()

    GiTF.Major.PhasePrompts.single_op_scope?(mission) or
      distinct_files <= @single_agent_max_files
  end

  # Adds a dependency from each op to any EARLIER op that touches one of
  # its files, unless a dependency path already exists. Emission order is
  # the tiebreak — the planner lists prerequisite work first.
  @doc false
  def serialize_shared_files(specs) do
    file_sets = Enum.map(specs, &MapSet.new(Map.get(&1, "target_files", [])))

    deps_by_index =
      specs
      |> Enum.with_index()
      |> Map.new(fn {spec, i} -> {i, List.wrap(Map.get(spec, "depends_on_indices", []))} end)

    specs
    |> Enum.with_index()
    |> Enum.map(fn {spec, j} ->
      files_j = Enum.at(file_sets, j)

      forced =
        for i <- 0..(j - 1)//1,
            not MapSet.disjoint?(files_j, Enum.at(file_sets, i)),
            not depends_transitively?(deps_by_index, j, i),
            do: i

      case forced do
        [] ->
          spec

        _ ->
          deps = (Map.fetch!(deps_by_index, j) ++ forced) |> Enum.uniq()
          Map.put(spec, "depends_on_indices", deps)
      end
    end)
  end

  defp depends_transitively?(deps_by_index, from, to, seen \\ MapSet.new()) do
    deps = Map.get(deps_by_index, from, [])

    cond do
      to in deps ->
        true

      MapSet.member?(seen, from) ->
        false

      true ->
        Enum.any?(deps, &depends_transitively?(deps_by_index, &1, to, MapSet.put(seen, from)))
    end
  end

  # Collapses a multi-op plan into one complete implementation brief:
  # ordered sections preserve each spec's intent, unions cover files and
  # acceptance criteria, and the model recommendation keeps the strongest
  # tier any spec asked for.
  defp merge_specs_into_one(mission, specs) do
    sections =
      specs
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {spec, i} ->
        "## Part #{i}: #{spec["title"] || "step"}\n\n#{spec["description"] || ""}"
      end)

    %{
      "title" => "Implement: " <> String.slice(mission.goal || "feature", 0, 90),
      "description" =>
        "Implement the COMPLETE feature end to end in this worktree. " <>
          "All parts below are one task — finish all of them before committing.\n\n" <>
          sections,
      "target_files" => specs |> Enum.flat_map(&(&1["target_files"] || [])) |> Enum.uniq(),
      "acceptance_criteria" =>
        specs |> Enum.flat_map(&(&1["acceptance_criteria"] || [])) |> Enum.uniq(),
      "model_recommendation" =>
        if(Enum.any?(specs, &(&1["model_recommendation"] == "thinking")),
          do: "thinking",
          else: "general"
        ),
      "verification_contract" =>
        specs |> Enum.map(& &1["verification_contract"]) |> Enum.find(& &1),
      "depends_on_indices" => []
    }
  end

  @doc """
  Tournament-mode op creation: call `create_jobs_from_specs/3` once per
  variant id, tagging each op with its variant. Dependencies stay
  variant-internal (each call has its own dependency-resolution scope),
  so v1's ops never block on v2's.

  Returns `{:ok, %{"v1" => [...], "v2" => [...]}}`.
  """
  @spec create_jobs_for_variants(String.t(), [map()], [String.t()]) ::
          {:ok, %{String.t() => [map()]}}
  def create_jobs_for_variants(mission_id, job_specs, variant_ids) do
    by_variant =
      Enum.reduce(variant_ids, %{}, fn variant_id, acc ->
        {:ok, ops} = create_jobs_from_specs(mission_id, job_specs, variant: variant_id)
        Map.put(acc, variant_id, ops)
      end)

    {:ok, by_variant}
  end

  # Scan all op pairs for target_files overlap and add implicit dependencies.
  # Earlier ops (lower index) become dependencies of later ops with shared files.
  defp add_file_overlap_dependencies(ops) do
    require Logger

    ops
    |> Enum.with_index()
    |> Enum.each(fn {op, idx} ->
      ops
      |> Enum.take(idx)
      |> Enum.each(fn earlier_op ->
        if GiTF.Conflict.files_overlap?(op.target_files, earlier_op.target_files) do
          case GiTF.Ops.add_dependency(op.id, earlier_op.id) do
            :ok ->
              overlap = GiTF.Conflict.overlapping_files(op.target_files, earlier_op.target_files)

              Logger.info(
                "Auto-added file overlap dependency: #{op.id} depends on #{earlier_op.id} (shared: #{Enum.join(overlap, ", ")})"
              )

            {:error, :already_exists} ->
              :ok

            {:error, reason} ->
              Logger.debug(
                "Could not add file overlap dependency #{op.id} -> #{earlier_op.id}: #{inspect(reason)}"
              )
          end
        end
      end)
    end)
  end

  defp resolve_model(tier) when is_binary(tier), do: GiTF.Runtime.ModelResolver.resolve(tier)
  defp resolve_model(other), do: other

  # Impl ops always resolve to `thinking` regardless of planning's
  # recommendation. Planning's LLM output defaults `model_recommendation`
  # to `"general"` (flash), which triggers flash's known tool-use loop
  # failure mode on implementation work.
  defp impl_op_model(_), do: resolve_model("thinking")

  # -- Multi-Plan Evaluation ---------------------------------------------------

  @default_strategies [
    %{name: "minimal", hint: "Bare-minimum implementation to achieve the goal"},
    %{name: "normal", hint: "Standard implementation with reasonable completeness"},
    %{
      name: "complex",
      hint: "Comprehensive implementation with thorough testing, edge cases, and documentation"
    }
  ]

  @doc """
  Discover whether a mission goal involves fundamentally different approaches.

  Calls haiku to classify the goal. If the goal involves a technology or
  approach choice (e.g., native vs cross-platform), returns up to 3 named
  alternative approaches. Otherwise returns the default scale tiers:
  minimal / normal / complex.
  """
  @spec discover_strategies(map(), map()) :: [%{name: String.t(), hint: String.t()}]
  def discover_strategies(_mission, _artifacts \\ %{}) do
    @default_strategies
  end

  @doc """
  Generates candidate plans using dynamically discovered strategies, scores each,
  stores all as `:plan_candidates` artifact, and returns the best one.

  Phase 1: Calls haiku to discover whether the goal needs alternative approaches
  or default scale tiers (minimal/normal/complex).
  Phase 2: Generates a sonnet plan for each strategy.

  Falls back to `generate_llm_plan/1` single plan on failure.
  """
  @spec generate_candidate_plans(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def generate_candidate_plans(mission_id, opts \\ %{}) do
    with {:ok, mission} <- GiTF.Missions.get(mission_id) do
      # Phase 1: Discover strategies
      artifacts = %{
        research: GiTF.Missions.get_artifact(mission_id, "research"),
        requirements: GiTF.Missions.get_artifact(mission_id, "requirements"),
        design: GiTF.Missions.get_artifact(mission_id, "design")
      }

      strategies = discover_strategies(mission, artifacts)

      # Phase 2: Generate a plan for each strategy
      candidates =
        strategies
        |> Enum.map(fn %{name: name, hint: hint} ->
          plan_opts = opts |> Map.put(:strategy, name) |> Map.put(:strategy_hint, hint)

          case generate_llm_plan(mission_id, plan_opts) do
            {:ok, plan} ->
              plan
              |> Map.put(:score, score_plan(plan))
              |> Map.put(:strategy, name)

            {:error, _} ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      if candidates == [] do
        # Fall back to single plan
        generate_llm_plan(mission_id, opts)
      else
        # Archive all candidates
        GiTF.Missions.store_artifact(mission_id, "plan_candidates", %{
          "candidates" =>
            Enum.map(candidates, fn c ->
              %{
                "strategy" => c.strategy,
                "score" => c.score,
                "task_count" => length(c.tasks),
                "estimated_duration" => c.estimated_duration
              }
            end),
          "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

        # Select best by score
        best = Enum.max_by(candidates, & &1.score)

        # Archive best plan as draft
        quest_record = Archive.get(:missions, mission_id)

        if quest_record do
          updated =
            quest_record
            |> Map.put(:draft_plan, best)
            |> Map.put(:plan_candidates, candidates)

          Archive.put(:missions, updated)
        end

        {:ok, best}
      end
    end
  end

  @doc """
  Scores a plan using a composite formula.

  Components (weights):
  - Task count efficiency (20%): fewer tasks = better (diminishing returns)
  - Parallelism potential (25%): tasks without deps / total tasks
  - Complexity distribution (20%): balanced mix of simple/moderate/complex
  - Estimated cost (15%): lower is better
  - Trust-based model confidence (20%): avg model trust for task types
  """
  @spec score_plan(map()) :: float()
  def score_plan(plan) do
    tasks = Map.get(plan, :tasks, [])

    if tasks == [] do
      0.0
    else
      task_score = score_task_count(length(tasks))
      parallel_score = score_parallelism(tasks)
      complexity_score = score_complexity_distribution(tasks)
      cost_score = score_estimated_cost(tasks)
      reputation_score = score_model_confidence(tasks)

      task_score * 0.20 +
        parallel_score * 0.25 +
        complexity_score * 0.20 +
        cost_score * 0.15 +
        reputation_score * 0.20
    end
  end

  @doc """
  Returns the next untried candidate plan for a mission.

  Reads `:tried_plans` from mission, returns next candidate not yet tried.
  """
  @spec select_fallback_plan(String.t()) :: {:ok, map()} | {:error, :no_fallback}
  def select_fallback_plan(mission_id) do
    mission = Archive.get(:missions, mission_id)
    candidates = Map.get(mission || %{}, :plan_candidates, [])
    tried = Map.get(mission || %{}, :tried_plans, [])
    tried_strategies = Enum.map(tried, & &1[:strategy])

    untried =
      candidates
      |> Enum.reject(fn c -> c.strategy in tried_strategies end)
      |> Enum.sort_by(& &1.score, :desc)

    case untried do
      [next | _] -> {:ok, next}
      [] -> {:error, :no_fallback}
    end
  end

  # -- Plan Scoring Helpers --------------------------------------------------

  defp score_task_count(count) do
    # Sweet spot: 2-5 tasks
    cond do
      count <= 1 -> 0.5
      count <= 5 -> 1.0
      count <= 10 -> 0.7
      true -> 0.4
    end
  end

  defp score_parallelism(tasks) do
    no_deps =
      Enum.count(tasks, fn t ->
        deps = t["depends_on_indices"] || []
        deps == []
      end)

    total = length(tasks)
    if total > 0, do: no_deps / total, else: 0.0
  end

  defp score_complexity_distribution(tasks) do
    models =
      Enum.map(tasks, fn t ->
        t["model_recommendation"] || "general"
      end)

    unique = Enum.uniq(models) |> length()
    # More variety in model selection = better distribution
    min(unique / 3.0, 1.0)
  end

  defp score_estimated_cost(tasks) do
    # Estimate based on model tiers
    total_cost =
      Enum.reduce(tasks, 0, fn t, acc ->
        model = t["model_recommendation"] || "general"

        cost =
          case model do
            m when m in ["fast", "haiku"] -> 1
            m when m in ["general", "sonnet"] -> 3
            m when m in ["thinking", "opus"] -> 10
            _ -> 3
          end

        acc + cost
      end)

    # Invert: lower cost = higher score
    max_cost = length(tasks) * 10
    if max_cost > 0, do: 1.0 - total_cost / max_cost, else: 1.0
  end

  defp score_model_confidence(tasks) do
    scores =
      Enum.map(tasks, fn t ->
        model = t["model_recommendation"] || "general"
        op_type = infer_op_type(t)
        rep = GiTF.Trust.model_reputation(model, op_type)
        if rep, do: rep.success_rate, else: 0.5
      end)

    if scores == [],
      do: 0.5,
      else: Enum.sum(scores) / length(scores)
  rescue
    _ -> 0.5
  end

  defp infer_op_type(task) do
    title = (task["title"] || "") |> String.downcase()

    cond do
      String.contains?(title, "test") -> :audit
      String.contains?(title, "research") -> :research
      String.contains?(title, "plan") -> :planning
      true -> :implementation
    end
  end

  # -- Adaptive Re-decomposition -----------------------------------------------

  @doc """
  Re-plan a mission from failure context.

  When all fallback plans are exhausted, analyzes what went wrong and
  generates a new plan that avoids the failed approaches.

  1. Collects failed op IDs from mission
  2. Runs FailureAnalysis on each
  3. Builds replan prompt with failure summaries
  4. Generates a new LLM plan with failure avoidance context

  Returns `{:ok, replan}` or `{:error, :replan_failed}`.
  """
  @spec replan_from_failures(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def replan_from_failures(mission_id, opts \\ %{}) do
    with {:ok, _quest} <- GiTF.Missions.get(mission_id) do
      # Collect failed ops
      failed_jobs =
        GiTF.Ops.list(mission_id: mission_id, status: "failed")

      if failed_jobs == [] do
        {:error, :no_failures}
      else
        # Analyze each failure
        analyses =
          failed_jobs
          |> Enum.map(fn op ->
            case GiTF.Intel.FailureAnalysis.analyze_failure(op.id) do
              {:ok, analysis} -> analysis
              {:error, _} -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        # Build failure context for the replan prompt
        failure_context = build_failure_context(failed_jobs, analyses)

        # Generate new plan with failure avoidance
        replan_opts =
          opts
          |> Map.put(:failure_context, failure_context)
          |> Map.put(:feedback, failure_context)

        case generate_llm_plan(mission_id, replan_opts) do
          {:ok, plan} ->
            plan = Map.put(plan, :replan, true)
            {:ok, plan}

          {:error, _reason} ->
            {:error, :replan_failed}
        end
      end
    end
  rescue
    e ->
      require Logger
      Logger.warning("Replan failed for mission: #{inspect(e)}")
      {:error, :replan_failed}
  end

  defp build_failure_context(failed_jobs, analyses) do
    job_summaries =
      failed_jobs
      |> Enum.map(fn op ->
        analysis = Enum.find(analyses, fn a -> a.op_id == op.id end)

        failure_type = if analysis, do: analysis.failure_type, else: :unknown
        root_cause = if analysis, do: analysis.root_cause, else: "Unknown"
        suggestions = if analysis, do: Enum.join(analysis.suggestions, "; "), else: ""

        "- Job \"#{op.title}\" failed (#{failure_type}): #{root_cause}. Suggestions: #{suggestions}"
      end)
      |> Enum.join("\n")

    """
    ## Previous Failures (AVOID THESE APPROACHES)

    The following ops failed in previous attempts. Your new plan MUST take
    a different approach and avoid the patterns that caused these failures:

    #{job_summaries}

    Design a plan that works around these known issues.
    """
  end

  # Goal-focused planning helpers

  defp define_acceptance_criteria(mission) do
    goal = Map.get(mission, :goal, Map.get(mission, :description, ""))

    [
      "Implementation achieves: #{goal}",
      "All tests pass",
      "Code is simple and readable",
      "No unnecessary features added",
      "Quality score >= 70"
    ]
  end

  defp define_scope_boundaries(mission) do
    goal = Map.get(mission, :goal, Map.get(mission, :description, ""))

    %{
      must_do: ["Implement #{goal}"],
      should_not_do: [
        "Add features not mentioned in goal",
        "Refactor unrelated code",
        "Add unnecessary abstractions",
        "Optimize prematurely"
      ],
      max_files: 10,
      max_complexity: :moderate
    }
  end

  defp calculate_simplicity_target(plan) do
    task_count = length(plan.tasks)

    cond do
      task_count <= 3 -> :very_simple
      task_count <= 5 -> :simple
      task_count <= 10 -> :moderate
      true -> :complex
    end
  end
end
