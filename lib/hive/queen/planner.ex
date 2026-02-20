defmodule Hive.Queen.Planner do
  @moduledoc """
  Queen's planning capabilities for Phase 2.3.
  
  Takes research summary and generates structured implementation plans
  with jobs, verification criteria, and context estimates.
  """

  alias Hive.Store
  alias Hive.Jobs.Classifier

  @doc """
  Generate implementation plan from research summary.
  
  Creates structured plan with jobs, dependencies, and verification criteria.
  Focuses on MINIMAL implementation to achieve stated goal.
  """
  @spec generate_plan(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def generate_plan(quest_id, research_summary) do
    with {:ok, quest} <- Hive.Quests.get(quest_id),
         {:ok, plan} <- create_implementation_plan(quest, research_summary) do
      
      # Add acceptance criteria and scope boundaries
      enhanced_plan = Map.merge(plan, %{
        acceptance_criteria: define_acceptance_criteria(quest),
        scope_boundaries: define_scope_boundaries(quest),
        simplicity_target: calculate_simplicity_target(plan)
      })
      
      # Store plan in quest
      quest_record = Store.get(:quests, quest_id)
      updated = Map.put(quest_record, :implementation_plan, enhanced_plan)
      Store.put(:quests, updated)
      
      {:ok, enhanced_plan}
    end
  end

  @doc """
  Create jobs from implementation plan.
  
  Converts plan structure into actual job records with dependencies.
  """
  @spec create_jobs_from_plan(String.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def create_jobs_from_plan(quest_id, plan) do
    with {:ok, quest} <- Hive.Quests.get(quest_id) do
      jobs = 
        plan.tasks
        |> Enum.with_index()
        |> Enum.map(fn {task, index} ->
          create_job_from_task(quest_id, quest.comb_id, task, index)
        end)
      
      # Create job records
      created_jobs = Enum.map(jobs, fn job_attrs ->
        {:ok, job} = Hive.Jobs.create(job_attrs)
        job
      end)
      
      # Add dependencies
      add_job_dependencies(created_jobs, plan.dependencies)
      
      {:ok, created_jobs}
    end
  end

  # Private helpers

  defp create_implementation_plan(quest, research_summary) do
    # Basic plan structure - would be enhanced with model-based planning
    plan = %{
      quest_id: quest.id,
      goal: quest.goal,
      research_input: research_summary,
      tasks: generate_basic_tasks(quest, research_summary),
      dependencies: [],
      verification_strategy: "automated_testing",
      estimated_duration: "2-4 hours",
      created_at: DateTime.utc_now()
    }
    
    {:ok, plan}
  end

  defp generate_basic_tasks(quest, research_summary) do
    # Generate basic task structure based on quest goal and research
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
        description: "Implement main functionality for: #{quest.goal}",
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
          type: :verification,
          complexity: :simple,
          estimated_tokens: 8000,
          verification_criteria: ["All tests pass", "Coverage > 80%"]
        }
      ]
      "javascript" -> [
        %{
          title: "Add tests",
          description: "Write Jest/Mocha tests",
          type: :verification,
          complexity: :simple,
          estimated_tokens: 8000,
          verification_criteria: ["All tests pass", "Coverage > 80%"]
        }
      ]
      _ -> [
        %{
          title: "Add validation",
          description: "Add basic validation and error handling",
          type: :verification,
          complexity: :simple,
          estimated_tokens: 5000,
          verification_criteria: ["Error handling works", "Input validation"]
        }
      ]
    end
    
    base_tasks ++ language_tasks
  end

  defp create_job_from_task(quest_id, comb_id, task, index) do
    classification = Classifier.classify_and_recommend(task.title, task.description)
    
    %{
      title: task.title,
      description: task.description,
      quest_id: quest_id,
      comb_id: comb_id,
      job_type: classification.job_type,
      complexity: classification.complexity,
      recommended_model: classification.recommended_model,
      verification_criteria: task.verification_criteria,
      estimated_context_tokens: task.estimated_tokens
    }
  end

  defp add_job_dependencies(jobs, dependencies) do
    # Add dependencies based on task order (sequential by default)
    jobs
    |> Enum.with_index()
    |> Enum.each(fn {job, index} ->
      if index > 0 do
        prev_job = Enum.at(jobs, index - 1)
        Hive.Jobs.add_dependency(job.id, prev_job.id)
      end
    end)
    
    # Add any custom dependencies from plan
    Enum.each(dependencies, fn {from_idx, to_idx} ->
      from_job = Enum.at(jobs, from_idx)
      to_job = Enum.at(jobs, to_idx)
      
      if from_job && to_job do
        Hive.Jobs.add_dependency(to_job.id, from_job.id)
      end
    end)
  end

  # Goal-focused planning helpers
  
  defp define_acceptance_criteria(quest) do
    goal = Map.get(quest, :goal, Map.get(quest, :description, ""))

    [
      "Implementation achieves: #{goal}",
      "All tests pass",
      "Code is simple and readable",
      "No unnecessary features added",
      "Quality score >= 70"
    ]
  end

  defp define_scope_boundaries(quest) do
    goal = Map.get(quest, :goal, Map.get(quest, :description, ""))

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