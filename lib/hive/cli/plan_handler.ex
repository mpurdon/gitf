defmodule Hive.CLI.PlanHandler do
  @moduledoc """
  Interactive planning sessions for quests.

  Public API used by CLI and QuestHandler to launch Claude-assisted planning
  before auto-starting quest execution.

  Supports three execution modes:
  - `:api` / `:ollama` — multi-turn chat via ReqLLM with tool calling
  - `:cli` — spawns Claude Code interactively (uses subscription, no API credits)
  """

  alias Hive.CLI.Format

  @doc """
  Launch an interactive planning session for a quest, then auto-start execution.
  """
  def start_interactive_planning(quest, _opts \\ []) do
    Format.info("Planning session for: #{quest.name}")

    mode = Hive.Runtime.ModelResolver.execution_mode()

    plan_result =
      if mode in [:api, :ollama, :bedrock] do
        Hive.CLI.Chat.start(quest)
      else
        run_cli_planning(quest)
      end

    case plan_result do
      {:ok, plan} ->
        create_jobs_from_plan(quest, plan)

      {:error, reason} ->
        Format.warn("Planning ended: #{inspect(reason)}")

      :no_plan ->
        start_quest_execution(quest)
    end
  end

  # -- CLI mode planning -----------------------------------------------------

  defp run_cli_planning(quest) do
    {:ok, root} = Hive.hive_dir()
    plan_dir = Path.join([root, ".hive", "planning", quest.id])
    File.mkdir_p!(plan_dir)

    plan_file = Path.join(plan_dir, "plan.json")
    # Remove stale plan file from previous attempts
    File.rm(plan_file)

    workspace = case quest.comb_id && Hive.Store.get(:combs, quest.comb_id) do
      nil -> root
      comb -> comb.path
    end

    system_prompt = build_cli_system_prompt(quest, plan_file)
    initial_prompt = build_cli_initial_prompt(quest)

    Format.info("Launching Claude Code for planning (uses your Claude subscription)")
    IO.puts("")

    case Hive.Runtime.Claude.spawn_interactive(workspace,
           system_prompt: system_prompt,
           prompt: initial_prompt) do
      {:ok, port} ->
        # Block until Claude exits
        receive do
          {^port, {:exit_status, _status}} -> :ok
        end

        # Restore terminal after Claude exits
        Hive.Runtime.Terminal.prepare_handoff()
        IO.puts("")

        # Try to read the plan file Claude wrote
        parse_cli_plan(plan_file)

      {:error, reason} ->
        Format.error("Failed to launch Claude Code: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_cli_plan(plan_file) do
    case File.read(plan_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, plan_data} ->
            Format.success("Plan received from Claude Code session.")
            plan = %{
              name: plan_data["name"] || "",
              summary: plan_data["summary"] || "",
              jobs: plan_data["jobs"] || []
            }
            {:ok, plan}

          {:error, _} ->
            Format.warn("Plan file exists but couldn't be parsed as JSON.")
            Format.info("You can create jobs manually with `hive job add`.")
            :no_plan
        end

      {:error, :enoent} ->
        Format.warn("No plan file was written by Claude.")
        Format.info("Tip: ask Claude to finalize the plan before exiting, or create jobs manually.")
        :no_plan

      {:error, reason} ->
        Format.error("Could not read plan file: #{inspect(reason)}")
        :no_plan
    end
  end

  defp build_cli_initial_prompt(quest) do
    codebase_hint = case quest.comb_id && Hive.Store.get(:combs, quest.comb_id) do
      nil -> ""
      comb -> " The codebase is at #{comb.path}."
    end

    "I want to plan: \"#{quest.goal}\"#{codebase_hint} " <>
      "Start by exploring the codebase to understand the current state, " <>
      "then ask me clarifying questions about what I need."
  end

  defp build_cli_system_prompt(quest, plan_file) do
    """
    You are an expert software architect helping plan the implementation of: "#{quest.goal}"

    ## Your Role
    Have an interactive conversation with the user to understand what they want, \
    explore the codebase, and collaboratively design an implementation plan.

    ## Planning Flow
    1. Ask clarifying questions about what the user wants
    2. Explore the codebase to understand the current state
    3. Discuss architecture and approach
    4. When the plan is ready, write it to a file

    ## CRITICAL: Writing the Plan
    When the user is satisfied with the plan, you MUST write a JSON file to:
    #{plan_file}

    The JSON must have this exact structure:
    ```json
    {
      "name": "Short quest name",
      "summary": "1-2 sentence summary of what we're building",
      "jobs": [
        {
          "title": "Job title",
          "description": "Detailed description with enough context for an AI agent to execute independently",
          "job_type": "implementation",
          "depends_on": []
        }
      ]
    }
    ```

    Job types: "research" (exploration/unknowns), "implementation" (coding), "verification" (testing)
    The `depends_on` array contains 0-based indices of prerequisite jobs.

    Keep jobs small and focused (1-3 hours of work each for an AI coding agent). \
    Each job description must be self-contained enough for an AI agent to execute without further context.

    Write the plan file as soon as the user confirms they're happy with it, then let them know it's saved.
    """
  end

  # -- Job creation ----------------------------------------------------------

  defp create_jobs_from_plan(quest, plan) do
    comb_id = quest.comb_id || first_comb_id()

    unless comb_id do
      Format.error("No comb available. Add a comb first with `hive comb add <repo>`.")
      return_early()
    end

    # Update quest name if the plan provided one
    if plan[:name] && plan[:name] != "" do
      case Hive.Store.get(:quests, quest.id) do
        nil -> :ok
        q -> Hive.Store.put(:quests, %{q | name: plan[:name]})
      end
    end

    # Create jobs from plan
    jobs = plan[:jobs] || []

    created =
      Enum.map(jobs, fn job_spec ->
        attrs = %{
          title: job_spec["title"],
          description: job_spec["description"],
          job_type: job_spec["job_type"] || "implementation",
          quest_id: quest.id,
          comb_id: comb_id
        }

        case Hive.Jobs.create(attrs) do
          {:ok, job} ->
            Format.success("  Job: #{job.title} (#{job.id})")
            job

          {:error, reason} ->
            Format.error("  Failed to create job: #{inspect(reason)}")
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Wire up dependencies
    Enum.each(Enum.with_index(jobs), fn {job_spec, idx} ->
      deps = job_spec["depends_on"] || []

      Enum.each(deps, fn dep_idx ->
        job = Enum.at(created, idx)
        dep = Enum.at(created, dep_idx)

        if job && dep do
          Hive.Jobs.add_dependency(job.id, dep.id)
        end
      end)
    end)

    Format.success("Created #{length(created)} job(s) for quest #{quest.id}.")
    start_quest_execution(quest)
  end

  defp start_quest_execution(quest) do
    answer = IO.gets("Start execution now? [y/n] ") |> String.trim() |> String.downcase()

    if answer in ["y", "yes", ""] do
      Format.info("Starting quest execution...")

      case Hive.Queen.Orchestrator.start_quest(quest.id) do
        {:ok, phase} ->
          Format.success("Quest #{quest.id} is now in #{phase} phase.")
          Format.info("Run `hive server` to monitor progress.")

        {:error, reason} ->
          Format.warn("Could not auto-start: #{inspect(reason)}")
      end
    else
      Format.info("Quest ready. Run `hive quest start #{quest.id}` when ready.")
    end
  end

  defp first_comb_id do
    case Hive.Store.all(:combs) do
      [comb | _] -> comb.id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp return_early, do: :ok

  @doc false
  def build_planning_prompt(quest) do
    """
    You are an expert software architect and planner.
    Your goal is to help the user plan the implementation of: "#{quest.goal}"

    Collaborate with the user to define:
    1. Research needs
    2. Requirements
    3. Architecture/Design
    4. Implementation Plan (Jobs)

    You have tools to read the codebase.
    Finally, produce a plan artifact using the `submit_plan` tool.
    """
  end

  @doc false
  def build_discovery_prompt(quest) do
    """
    You are an expert software architect helping a user discover and define their project goal.

    The user started a new quest but hasn't specified a concrete goal yet.
    Quest: #{quest.name} (#{quest.id})

    Help the user by:
    1. Asking what they want to build or change
    2. Exploring the codebase to understand the current state
    3. Clarifying scope and constraints
    4. Once the goal is clear, collaboratively plan the implementation

    Then produce a plan artifact using the `submit_plan` tool.
    Be conversational and curious — draw the goal out of the user.
    """
  end
end
