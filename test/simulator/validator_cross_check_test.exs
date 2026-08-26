defmodule GiTF.Simulator.ValidatorCrossCheckTest do
  @moduledoc """
  Validator cross-check (priority 1 from the reliability fixes):
  when the validator returns "pass" but the impl op committed nothing
  meaningful, the orchestrator must override to "fail" and not ship a
  PR for an empty mission.

  Without this guard, a hallucinated PASS would slip through
  validation → sync → publish, opening a PR with no changes.
  """
  use ExUnit.Case, async: false

  alias GiTF.Test.{ScriptedLLMClient, Simulator}

  @moduletag :simulator

  describe "validator pass with no commits is overridden to fail" do
    @tag timeout: 180_000
    test "mission with non-committing impl ghost does not pass validation" do
      {:ok, sim_ctx} =
        Simulator.setup_scenario(
          rules: rules_pass_without_commits(sim_ctx_sector_id_ref()),
          sector_name: "xcheck-#{:erlang.unique_integer([:positive])}",
          files: %{"app/main.js" => "// initial\n"}
        )

      on_exit(fn -> Simulator.reset!(sim_ctx) end)

      # Stash sector_id so the side_effect (which runs AT impl-call time
      # — when the ghost worktree exists) can locate the worktree.
      :persistent_term.put(sim_ctx_sector_id_ref(), sim_ctx.sector.id)
      on_exit(fn -> :persistent_term.erase(sim_ctx_sector_id_ref()) end)

      {:ok, mission} =
        Simulator.create_mission(sim_ctx, goal: "Cross-check: only .claude/ commits")

      result = Simulator.run(sim_ctx, mission.id, max_ticks: 600)

      outcome =
        case result do
          {:ok, o} -> o
          {:timeout, info} -> info
        end

      # Critical invariant: mission MUST NOT reach "completed". A pass
      # with no real commits would otherwise ship a vacuous PR.
      refute outcome[:status] == "completed",
             "validator hallucinated pass + only-.claude/ commits should NOT complete: " <>
               inspect(outcome)

      # The cross-check fires: overall_verdict was demoted to "fail"
      # and a cross_check_override marker is recorded on the artifact.
      validation = GiTF.Missions.get_artifact(mission.id, "validation") || %{}

      assert validation["overall_verdict"] == "fail",
             "validation artifact should be overridden to fail: #{inspect(validation)}"

      assert validation["cross_check_override"],
             "expected cross_check_override field on validation artifact: " <>
               inspect(validation)

      # Telemetry signal also fires (read by alerting + dashboards).
      _ = outcome
    end
  end

  defp sim_ctx_sector_id_ref, do: :validator_xcheck_sector_id

  # Side effect that commits only `.claude/` files in the impl ghost's
  # worktree — exactly the scenario the cross-check is designed to
  # catch (validator says pass, but the only commits are settings).
  defp commit_only_claude_files do
    sector_id =
      try do
        :persistent_term.get(sim_ctx_sector_id_ref())
      rescue
        _ -> nil
      end

    if sector_id do
      mission =
        case GiTF.Archive.filter(:missions, fn m -> m[:sector_id] == sector_id end) do
          [m | _] -> m
          _ -> nil
        end

      if mission do
        Simulator.simulate_impl_commit(
          mission.id,
          [{".claude/instructions.md", "# generated settings only\n"}],
          "sim: only .claude/ settings"
        )
      end
    end
  rescue
    _ -> :ok
  end

  defp rules_pass_without_commits(_sector_ref) do
    [
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
              "goal_restatement" => "Sim",
              "external_resource_urls" => [],
              "bug_reproducible" => true,
              "bug_evidence" => "app/main.js:1"
            })
          )
      },

      # Impl ghost returns text and side_effect commits ONLY `.claude/`
      # — exactly the failure mode the cross-check is designed to catch.
      %{
        match: ~r/Implement:/,
        response: ScriptedLLMClient.ok_text("Done."),
        side_effect: &commit_only_claude_files/0
      },

      # Validator hallucinates PASS — no gaps, claim everything works.
      # Cross-check should override to fail.
      %{
        match: ~r/# Validation Phase/,
        consume: false,
        response:
          ScriptedLLMClient.ok_text(
            ScriptedLLMClient.json_artifact(%{
              "requirements_met" => [
                %{"req_id" => "FR-1", "met" => true, "evidence" => "fake"}
              ],
              "gaps" => [],
              "overall_verdict" => "pass",
              "summary" => "all good (lying)"
            })
          )
      },

      # Fix-op responses (in case cross-check routes to the fix loop)
      %{
        match: ~r/## Validation Feedback/,
        consume: false,
        response: ScriptedLLMClient.ok_text("Tried fix.")
      },

      # Simplify rules (needed if mission somehow reaches simplify)
      simplify_rule("Code Reuse Review"),
      simplify_rule("Code Quality Review"),
      simplify_rule("(?:Code\\s)?Efficiency Review"),
      %{
        match: ~r/# Final Scoring/,
        response:
          ScriptedLLMClient.ok_text(
            ScriptedLLMClient.json_artifact(%{
              "overall_score" => 50,
              "dimension_scores" => %{
                "final_output" => 50,
                "trajectory" => 50,
                "tool_usage" => 50,
                "safety_alignment" => 50
              },
              "summary" => "n/a"
            })
          )
      }
    ]
  end

  defp simplify_rule(focus_pattern) do
    %{
      match: ~r/# #{focus_pattern}/,
      response:
        ScriptedLLMClient.ok_text(
          ScriptedLLMClient.json_artifact(%{
            "issues_found" => 0,
            "issues_fixed" => 0,
            "changes" => [],
            "summary" => "clean"
          })
        )
    }
  end
end
