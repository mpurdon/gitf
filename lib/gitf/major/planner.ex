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
      enhanced_plan = Map.merge(plan, %{
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
      created_jobs = Enum.map(ops, fn job_attrs ->
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
    language_tasks = case main_language do
      "elixir" -> [
        %{
          title: "Add tests",
          description: "Write comprehensive ExUnit tests",
          type: :audit,
          complexity: :simple,
          estimated_tokens: 8000,
          verification_criteria: ["All tests pass", "Coverage > 80%"]
        }
      ]
      "javascript" -> [
        %{
          title: "Add tests",
          description: "Write Jest/Mocha tests",
          type: :audit,
          complexity: :simple,
          estimated_tokens: 8000,
          verification_criteria: ["All tests pass", "Coverage > 80%"]
        }
      ]
      _ -> [
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

      case GiTF.Runtime.Models.generate_text(prompt, model: "sonnet") do
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
              {:ok, %{
                mission_id: mission_id,
                goal: mission.goal,
                tasks: [%{
                  "title" => "Implementation",
                  "description" => text,
                  "target_files" => [],
                  "model_recommendation" => "sonnet"
                }],
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
            if(research, do: "## Research\n```json\n#{Jason.encode!(research, pretty: true)}\n```"),
            if(requirements, do: "## Requirements\n```json\n#{Jason.encode!(requirements, pretty: true)}\n```"),
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
        6. Recommend model complexity (sonnet for simple, opus for complex)

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
            "model_recommendation": "sonnet"
          }
        ]
        ```

        Keep the number of ops minimal. Prefer fewer, larger ops over many small ones.
        """
    end
  end

  @doc false
  def strategy_instruction(nil, _), do: ""
  def strategy_instruction(name, hint) when is_binary(hint),
    do: "STRATEGY: \"#{name}\" — #{hint}. Design the plan accordingly."
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
  """
  @spec create_jobs_from_specs(String.t(), [map()]) :: {:ok, [map()]}
  def create_jobs_from_specs(mission_id, job_specs) do
    mission = Archive.get(:missions, mission_id)
    sector_id = if mission, do: mission.sector_id

    {ops, _id_map} =
      job_specs
      |> Enum.with_index()
      |> Enum.reduce({[], %{}}, fn {spec, idx}, {acc, id_map} ->
        job_attrs = %{
          title: spec["title"] || "Job #{idx + 1}",
          description: spec["description"],
          mission_id: mission_id,
          sector_id: sector_id,
          acceptance_criteria: spec["acceptance_criteria"] || [],
          target_files: spec["target_files"] || [],
          phase_job: false,
          assigned_model: resolve_model(spec["model_recommendation"]),
          verification_contract: spec["verification_contract"]
        }

        case GiTF.Ops.create(job_attrs) do
          {:ok, op} ->
            # Resolve dependencies by index
            for dep_idx <- (spec["depends_on_indices"] || []) do
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

    {:ok, Enum.reverse(ops)}
  end

  defp resolve_model("opus"), do: "claude-opus-4-6"
  defp resolve_model("sonnet"), do: "claude-sonnet-4-6"
  defp resolve_model(nil), do: nil
  defp resolve_model(other), do: other

  # -- Multi-Plan Evaluation ---------------------------------------------------

  @default_strategies [
    %{name: "minimal", hint: "Bare-minimum implementation to achieve the goal"},
    %{name: "normal", hint: "Standard implementation with reasonable completeness"},
    %{name: "complex", hint: "Comprehensive implementation with thorough testing, edge cases, and documentation"}
  ]

  @doc """
  Discover whether a mission goal involves fundamentally different approaches.

  Calls haiku to classify the goal. If the goal involves a technology or
  approach choice (e.g., native vs cross-platform), returns up to 3 named
  alternative approaches. Otherwise returns the default scale tiers:
  minimal / normal / complex.
  """
  @spec discover_strategies(map(), map()) :: [%{name: String.t(), hint: String.t()}]
  def discover_strategies(mission, artifacts \\ %{}) do
    artifacts_context =
      artifacts
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map(fn {k, _v} -> "- #{k} artifact available" end)
      |> Enum.join("\n")

    artifacts_section = if artifacts_context != "", do: "\nAvailable artifacts:\n#{artifacts_context}\n", else: ""

    prompt = """
    You are classifying a project goal.

    Goal: #{mission.goal}
    #{artifacts_section}
    Does this goal involve a fundamental technology or approach choice (e.g., native vs cross-platform,
    different languages, different frameworks/SDKs)?

    If YES — output up to 3 alternative approaches as JSON:
    ```json
    [
      {"name": "short-kebab-name", "hint": "One-line description of this approach"},
      ...
    ]
    ```

    If NO — output exactly:
    ```json
    [
      {"name": "minimal", "hint": "Bare-minimum implementation to achieve the goal"},
      {"name": "normal",  "hint": "Standard implementation with reasonable completeness"},
      {"name": "complex", "hint": "Comprehensive implementation with thorough testing, edge cases, and documentation"}
    ]
    ```
    """

    case GiTF.Runtime.Models.generate_text(prompt, model: "haiku") do
      {:ok, response} ->
        text = extract_text(response)
        parse_strategies(text)

      {:error, _} ->
        @default_strategies
    end
  end

  defp parse_strategies(text) do
    json_str =
      case Regex.run(~r/```json\s*\n(.*?)\n\s*```/s, text) do
        [_, json] -> json
        _ -> text
      end

    case Jason.decode(json_str) do
      {:ok, list} when is_list(list) and length(list) > 0 ->
        Enum.map(list, fn item ->
          %{
            name: item["name"] || "unknown",
            hint: item["hint"] || ""
          }
        end)

      _ ->
        @default_strategies
    end
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
          "candidates" => Enum.map(candidates, fn c ->
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
        t["model_recommendation"] || "sonnet"
      end)

    unique = Enum.uniq(models) |> length()
    # More variety in model selection = better distribution
    min(unique / 3.0, 1.0)
  end

  defp score_estimated_cost(tasks) do
    # Estimate based on model tiers
    total_cost =
      Enum.reduce(tasks, 0, fn t, acc ->
        model = t["model_recommendation"] || "sonnet"

        cost =
          case model do
            "haiku" -> 1
            "sonnet" -> 3
            "opus" -> 10
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
        model = t["model_recommendation"] || "sonnet"
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