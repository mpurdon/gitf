defmodule Hive.CLI.PlanHandler do
  @moduledoc """
  CLI handler for interactive planning sessions.
  """

  alias Hive.CLI.Format

  def dispatch([:plan], result, helpers) do
    # Check if we are resuming a quest or starting a new one
    quest_id = helpers.result_get.(result, :options, :quest)
    goal = helpers.result_get.(result, :args, :goal)

    quest =
      cond do
        quest_id ->
          case Hive.Quests.get(quest_id) do
            {:ok, q} -> q
            _ -> 
              Format.error("Quest not found: #{quest_id}")
              System.halt(1)
          end

        goal ->
          # New quest
          # Must resolve comb first
          case helpers.resolve_comb_id.(helpers.result_get.(result, :options, :comb)) do
            {:ok, comb_id} ->
              {:ok, q} = Hive.Quests.create(%{goal: goal, comb_id: comb_id})
              Format.success("Created quest: #{q.name} (#{q.id})")
              q
            
            {:error, :no_comb} ->
              Format.error("No comb specified. Use --comb.")
              System.halt(1)
          end

        true ->
          Format.error("Usage: hive plan \"<goal>\" OR hive plan --quest <id>")
          System.halt(1)
      end

    start_interactive_planning(quest)
  end

  def dispatch(_path, _result, _helpers), do: :not_handled

  defp start_interactive_planning(quest) do
    Format.info("Starting interactive planning session for: #{quest.name}")
    Format.info("Type 'exit' or 'done' to finish.")

    # We need to spawn an interactive bee attached to the TUI/Console
    # Use Hive.Runtime.Models.spawn_interactive but configured for planning context
    
    # 1. Setup workspace (maybe use queen workspace or temp)
    {:ok, root} = Hive.hive_dir()
    workspace = Path.join([root, ".hive", "planning", quest.id])
    File.mkdir_p!(workspace)
    
    # 2. Generate planning context prompt
    system_prompt = """
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
    
    # 3. Launch interactive session
    # Note: spawn_interactive launches the CLI tool which takes over stdio.
    # We pass the system prompt if the tool supports it, or we rely on the user to paste it?
    # Actually, we should use `Hive.Runtime.AgentLoop` if we want to inject system prompt cleanly
    # and handle tools, but AgentLoop is for API mode.
    
    # If the user wants "interactive", they usually mean a chat interface.
    # If we are in API mode (Gemini), we use AgentLoop.
    # If we are in CLI mode (Claude), we spawn `claude` process.
    
    mode = Hive.Runtime.ModelResolver.execution_mode()
    
    if mode == :api do
      # API Mode (Gemini/Claude API): Use AgentLoop attached to IO
      run_interactive_api_loop(system_prompt, workspace, quest)
    else
      # CLI Mode (Claude Code): Spawn it
      # We can't easily inject system prompt into `claude` CLI startup args except via -p
      # But -p is the initial user message.
      
      Format.info("Launching Claude Code...")
      Hive.Runtime.Models.spawn_interactive(workspace, prompt: system_prompt)
    end
  end

  defp run_interactive_api_loop(_system_prompt, _workspace, _quest) do
    # We need a REPL that feeds user input to AgentLoop
    # This is complex because AgentLoop is designed for autonomous execution.
    # We need a `ChatLoop` module or similar.
    
    # For now, let's use a simplified loop:
    # 1. User inputs message.
    # 2. Call LLM with history.
    # 3. Print response.
    # 4. Repeat.
    
    # But we want it to have tools and context.
    
    Format.warn("Interactive chat for API mode is experimental.")
    
    # TODO: Implement full REPL.
    # For this MVP, we will direct the user to use the Dashboard or just run `hive quest new`
    # and let the automated planner run, then review the artifact.
    
    # But the user specifically asked for "go through an extensive planning session".
    # This implies a Chat UI.
    
    IO.puts("Interactive planning in API mode requires a chat interface.")
    IO.puts("Please use the Hive Web Dashboard (coming soon) or switch to CLI mode.")
  end
end
