defmodule Hive.CLI.PlanHandler do
  @moduledoc """
  Interactive planning sessions for quests.

  Public API used by CLI and QuestHandler to launch Claude-assisted planning
  before auto-starting quest execution.
  """

  alias Hive.CLI.Format

  @doc """
  Launch an interactive planning session for a quest, then auto-start execution.

  ## Options

    * `:interactive_goal` — when `true`, uses a discovery-focused prompt that
      helps the user define their goal before planning (default: `false`)
  """
  def start_interactive_planning(quest, opts \\ []) do
    Format.info("Planning session for: #{quest.name}")
    {:ok, root} = Hive.hive_dir()
    workspace = Path.join([root, ".hive", "planning", quest.id])
    File.mkdir_p!(workspace)

    system_prompt =
      if opts[:interactive_goal],
        do: build_discovery_prompt(quest),
        else: build_planning_prompt(quest)

    mode = Hive.Runtime.ModelResolver.execution_mode()

    if mode == :api do
      Format.warn("API mode: skipping interactive session, starting automated pipeline.")
    else
      Format.info("Launching Claude Code for planning...")

      case Hive.Runtime.Models.spawn_interactive(workspace, prompt: system_prompt) do
        {:ok, port} when is_port(port) ->
          receive do
            {^port, {:exit_status, _}} -> :ok
          end

        {:error, reason} ->
          Format.error("Failed to launch: #{inspect(reason)}")
      end
    end

    # Auto-start quest execution
    Format.info("Starting quest execution...")

    case Hive.Queen.Orchestrator.start_quest(quest.id) do
      {:ok, phase} ->
        Format.success("Quest #{quest.id} is now in #{phase} phase.")
        Format.info("Run `hive server` to monitor progress.")

      {:error, reason} ->
        Format.warn("Could not auto-start: #{inspect(reason)}")
    end
  end

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
