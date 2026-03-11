defmodule GiTF.CLI.PlanHandler do
  @moduledoc """
  Interactive planning sessions for missions.

  Public API used by CLI and MissionHandler to launch Claude-assisted planning
  before auto-starting mission execution.

  Supports three execution modes:
  - `:api` / `:ollama` — multi-turn chat via ReqLLM with tool calling
  - `:cli` — spawns Claude Code interactively (uses subscription, no API credits)
  """

  alias GiTF.CLI.Format

  @doc """
  Launch an interactive planning session for a mission, then auto-start execution.
  """
  def start_interactive_planning(mission, _opts \\ []) do
    Format.info("Planning session for: #{mission.name}")

    mode = GiTF.Runtime.ModelResolver.execution_mode()

    plan_result =
      if mode in [:api, :ollama, :bedrock] do
        GiTF.CLI.Chat.start(mission)
      else
        run_cli_planning(mission)
      end

    case plan_result do
      {:ok, plan} ->
        create_jobs_from_plan(mission, plan)

      {:error, reason} ->
        Format.warn("Planning ended: #{inspect(reason)}")

      :no_plan ->
        start_quest_execution(mission)
    end
  end

  # -- CLI mode planning -----------------------------------------------------

  defp run_cli_planning(mission) do
    {:ok, root} = GiTF.gitf_dir()
    plan_dir = Path.join([root, ".gitf", "planning", mission.id])
    File.mkdir_p!(plan_dir)

    plan_file = Path.join(plan_dir, "plan.json")
    # Remove stale plan file from previous attempts
    File.rm(plan_file)

    workspace = case mission.sector_id && GiTF.Archive.get(:sectors, mission.sector_id) do
      nil -> root
      sector -> sector.path
    end

    system_prompt = build_cli_system_prompt(mission, plan_file)
    initial_prompt = build_cli_initial_prompt(mission)

    Format.info("Launching Claude Code for planning (uses your Claude subscription)")
    IO.puts("")

    case GiTF.Runtime.Claude.spawn_interactive(workspace,
           system_prompt: system_prompt,
           prompt: initial_prompt) do
      {:ok, port} ->
        # Block until Claude exits
        receive do
          {^port, {:exit_status, _status}} -> :ok
        end

        # Restore terminal after Claude exits
        GiTF.Runtime.Terminal.prepare_handoff()
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
              ops: plan_data["ops"] || []
            }
            {:ok, plan}

          {:error, _} ->
            Format.warn("Plan file exists but couldn't be parsed as JSON.")
            Format.info("You can create ops manually with `gitf op add`.")
            :no_plan
        end

      {:error, :enoent} ->
        Format.warn("No plan file was written by Claude.")
        Format.info("Tip: ask Claude to finalize the plan before exiting, or create ops manually.")
        :no_plan

      {:error, reason} ->
        Format.error("Could not read plan file: #{inspect(reason)}")
        :no_plan
    end
  end

  defp build_cli_initial_prompt(mission) do
    codebase_hint = case mission.sector_id && GiTF.Archive.get(:sectors, mission.sector_id) do
      nil -> ""
      sector -> " The codebase is at #{sector.path}."
    end

    "I want to plan: \"#{mission.goal}\"#{codebase_hint} " <>
      "Start by exploring the codebase to understand the current state, " <>
      "then ask me clarifying questions about what I need."
  end

  defp build_cli_system_prompt(mission, plan_file) do
    """
    You are an expert software architect helping plan the implementation of: "#{mission.goal}"

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
      "name": "Short mission name",
      "summary": "1-2 sentence summary of what we're building",
      "ops": [
        {
          "title": "Job title",
          "description": "Detailed description with enough context for an AI agent to execute independently",
          "op_type": "implementation",
          "depends_on": []
        }
      ]
    }
    ```

    Job types: "research" (exploration/unknowns), "implementation" (coding), "verification" (testing)
    The `depends_on` array contains 0-based indices of prerequisite ops.

    Keep ops small and focused (1-3 hours of work each for an AI coding agent). \
    Each op description must be self-contained enough for an AI agent to execute without further context.

    Write the plan file as soon as the user confirms they're happy with it, then let them know it's saved.
    """
  end

  # -- Job creation ----------------------------------------------------------

  defp create_jobs_from_plan(mission, plan) do
    sector_id = mission.sector_id || first_comb_id()

    unless sector_id do
      Format.error("No sector available. Add a sector first with `gitf sector add <repo>`.")
      return_early()
    end

    # Update mission name if the plan provided one
    if plan[:name] && plan[:name] != "" do
      case GiTF.Archive.get(:missions, mission.id) do
        nil -> :ok
        q -> GiTF.Archive.put(:missions, %{q | name: plan[:name]})
      end
    end

    # Create ops from plan
    ops = plan[:ops] || []

    created =
      Enum.map(ops, fn job_spec ->
        attrs = %{
          title: job_spec["title"],
          description: job_spec["description"],
          op_type: job_spec["op_type"] || "implementation",
          mission_id: mission.id,
          sector_id: sector_id
        }

        case GiTF.Ops.create(attrs) do
          {:ok, op} ->
            Format.success("  Job: #{op.title} (#{op.id})")
            op

          {:error, reason} ->
            Format.error("  Failed to create op: #{inspect(reason)}")
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Wire up dependencies
    Enum.each(Enum.with_index(ops), fn {job_spec, idx} ->
      deps = job_spec["depends_on"] || []

      Enum.each(deps, fn dep_idx ->
        op = Enum.at(created, idx)
        dep = Enum.at(created, dep_idx)

        if op && dep do
          GiTF.Ops.add_dependency(op.id, dep.id)
        end
      end)
    end)

    Format.success("Created #{length(created)} op(s) for mission #{mission.id}.")
    start_quest_execution(mission)
  end

  defp start_quest_execution(mission) do
    answer = IO.gets("Start execution now? [y/n] ") |> String.trim() |> String.downcase()

    if answer in ["y", "yes", ""] do
      Format.info("Starting mission execution...")

      case GiTF.Major.Orchestrator.start_quest(mission.id) do
        {:ok, phase} ->
          Format.success("Quest #{mission.id} is now in #{phase} phase.")
          Format.info("Run `gitf server` to monitor progress.")

        {:error, reason} ->
          Format.warn("Could not auto-start: #{inspect(reason)}")
      end
    else
      Format.info("Quest ready. Run `gitf mission start #{mission.id}` when ready.")
    end
  end

  defp first_comb_id do
    case GiTF.Archive.all(:sectors) do
      [sector | _] -> sector.id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp return_early, do: :ok

  @doc false
  def build_planning_prompt(mission) do
    """
    You are an expert software architect and planner.
    Your goal is to help the user plan the implementation of: "#{mission.goal}"

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
  def build_discovery_prompt(mission) do
    """
    You are an expert software architect helping a user discover and define their project goal.

    The user started a new mission but hasn't specified a concrete goal yet.
    Quest: #{mission.name} (#{mission.id})

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
