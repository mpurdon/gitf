defmodule GiTF.Simulator.HappyPathTest do
  @moduledoc """
  End-to-end simulation: GH-issue-like mission with scripted LLM
  responses. Exercises the real orchestrator + real git worktree + real
  Archive, but NEVER hits a live LLM provider.

  This is the baseline reliability gate — if this can't run green, the
  pipeline isn't safe to run against real credits.
  """
  # NOTE: NOT using GiTF.StoreCase — that restarts the Archive, which
  # disconnects Major and MissionSupervisor from the data they need to
  # spawn ghosts. We use the application-started supervision tree as-is
  # and scope each test's reset to its sector.
  use ExUnit.Case, async: false

  alias GiTF.Test.{ScriptedLLMClient, Simulator}

  @moduletag :simulator

  setup context do
    rules = happy_path_rules()

    {:ok, sim_ctx} =
      Simulator.setup_scenario(
        rules: rules,
        sector_name: "happy-#{:erlang.unique_integer([:positive])}",
        files: %{
          "app/src/components/DiffViewer.tsx" => ~s|// before: "Collapse Low"\n|
        }
      )

    on_exit(fn -> Simulator.reset!(sim_ctx) end)

    Map.merge(context, %{sim_ctx: sim_ctx})
  end

  test "mission with fast pipeline reaches completed", %{sim_ctx: sim_ctx} do
    {:ok, mission} =
      Simulator.create_mission(sim_ctx,
        goal:
          "Fix GH-40: Collapse All label is incorrect. Should be 'Collapse All' not 'Collapse Low'."
      )

    # Rebuild rules now that we know the mission id — the impl rule needs
    # the mission id to simulate a commit in its shell worktree.
    new_rules =
      Enum.map(sim_ctx.scenario_rules, fn rule ->
        case rule do
          %{match: %Regex{source: "Implement:"}} = r ->
            Map.put(r, :side_effect, fn ->
              Simulator.simulate_impl_commit(
                mission.id,
                [{"app/src/components/DiffViewer.tsx", ~s|// after: "Collapse All"\n|}]
              )
            end)

          other ->
            other
        end
      end)

    {:ok, _pid} = ScriptedLLMClient.start_scenario(new_rules)

    {:ok, outcome} = Simulator.run(sim_ctx, mission.id, max_ticks: 200)

    assert outcome.status == "completed",
           "mission did not complete cleanly: #{inspect(outcome, pretty: true)}"

    phases = outcome.phases_seen
    assert "triage" in phases, "triage phase not observed: #{inspect(phases)}"
    assert "implementation" in phases, "impl phase not observed: #{inspect(phases)}"

    # No LLM prompt went unmatched — if any did, rules are incomplete
    assert ScriptedLLMClient.unmatched_count() == 0,
           "scripted LLM saw unmatched prompts: #{inspect(outcome.llm_calls)}"
  end

  # -- Scenario data ----------------------------------------------------------

  defp happy_path_rules do
    [
      # Triage returns a clean "simple complexity, no skip flags" verdict
      %{
        match: ~r/# Triage Phase/,
        response:
          ScriptedLLMClient.ok_text(
            ScriptedLLMClient.json_artifact(%{
              "complexity" => "simple",
              "skip_flags" => %{
                "skip_research" => true,
                "skip_requirements" => true,
                "skip_design" => true,
                "skip_review" => true,
                "skip_planning" => true
              },
              "goal_restatement" => "Change button label 'Collapse Low' to 'Collapse All'",
              "external_resource_urls" => [],
              "bug_reproducible" => true,
              "bug_evidence" => "app/src/components/DiffViewer.tsx:1"
            })
          )
      },

      # Impl ghost — emits a short completion text (won't actually commit
      # in the sim; the orchestrator only checks the op status/artifact).
      # The real reliability value comes from later scenarios that
      # exercise the full commit path; happy-path here verifies the
      # orchestration machinery advances correctly.
      %{
        match: ~r/Implement:/i,
        response:
          ScriptedLLMClient.ok_text("""
          I updated DiffViewer.tsx to use "Collapse All" instead of "Collapse Low".
          """)
      },

      # Validation returns pass
      %{
        match: ~r/# Validation Phase/,
        response:
          ScriptedLLMClient.ok_text(
            ScriptedLLMClient.json_artifact(%{
              "requirements_met" => [
                %{
                  "req_id" => "FR-1",
                  "met" => true,
                  "evidence" => "DiffViewer.tsx now shows 'Collapse All'"
                }
              ],
              "gaps" => [],
              "overall_verdict" => "pass",
              "summary" => "Label fix correctly applied"
            })
          )
      },

      # Simplify reviewers (3 parallel agents): each returns an empty
      # findings block. Matches by the focus label in the prompt.
      %{
        match: ~r/# Code Reuse Review/,
        response:
          ScriptedLLMClient.ok_text(
            ScriptedLLMClient.json_artifact(%{
              "issues_found" => 0,
              "issues_fixed" => 0,
              "changes" => [],
              "summary" => "Nothing to consolidate"
            })
          )
      },
      %{
        match: ~r/# Code Quality Review/,
        response:
          ScriptedLLMClient.ok_text(
            ScriptedLLMClient.json_artifact(%{
              "issues_found" => 0,
              "issues_fixed" => 0,
              "changes" => [],
              "summary" => "Clean"
            })
          )
      },
      %{
        match: ~r/# (?:Code\s)?Efficiency Review/,
        response:
          ScriptedLLMClient.ok_text(
            ScriptedLLMClient.json_artifact(%{
              "issues_found" => 0,
              "issues_fixed" => 0,
              "changes" => [],
              "summary" => "No perf concerns"
            })
          )
      },

      # Scoring (async post-processing)
      %{
        match: ~r/# Final Scoring/,
        response:
          ScriptedLLMClient.ok_text(
            ScriptedLLMClient.json_artifact(%{
              "overall_score" => 92,
              "dimension_scores" => %{
                "final_output" => 95,
                "trajectory" => 90,
                "tool_usage" => 90,
                "safety_alignment" => 95
              },
              "summary" => "Clean, minimal change."
            })
          )
      }
    ]
  end
end
