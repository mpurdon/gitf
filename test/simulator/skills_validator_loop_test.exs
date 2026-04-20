defmodule GiTF.Simulator.SkillsValidatorLoopTest do
  @moduledoc """
  M2 end-to-end gate: validation failure → refinement drafts a skill →
  critic approves → skill lands in Archive.

  The loop-closure property (future mission succeeds where this one
  failed) is covered at the unit level — refinement_test.exs proves the
  Archive write happens, retrieval_test.exs proves it's picked up next
  time. This simulator scenario proves the orchestrator wiring fires
  the refinement task correctly after validation.
  """

  use ExUnit.Case, async: false

  alias GiTF.Test.{ScriptedLLMClient, Simulator}

  @moduletag :simulator

  setup do
    prev_refine = Application.get_env(:gitf, :skill_refinement_enabled)
    prev_commit = Application.get_env(:gitf, :skill_auto_commit_enabled)

    Application.put_env(:gitf, :skill_refinement_enabled, true)
    Application.put_env(:gitf, :skill_auto_commit_enabled, true)

    on_exit(fn ->
      restore(:skill_refinement_enabled, prev_refine)
      restore(:skill_auto_commit_enabled, prev_commit)
    end)

    {:ok, sim_ctx} =
      Simulator.setup_scenario(
        rules: scenario_rules(),
        sector_name: "skills-loop-#{:erlang.unique_integer([:positive])}",
        files: %{"app/main.js" => "// initial\n"}
      )

    on_exit(fn -> Simulator.reset!(sim_ctx) end)

    %{sim_ctx: sim_ctx}
  end

  @tag timeout: 180_000
  test "validation failure triggers refiner + critic and commits a draft", %{sim_ctx: sim_ctx} do
    {:ok, mission} = Simulator.create_mission(sim_ctx, goal: "Fix the missing bug")

    # Kick off the mission run in the background; we poll for the drafted
    # skill rather than waiting for mission termination. The fix-loop may
    # run to exhaustion (which is fine) — the refinement that matters
    # fires on the first validation fail.
    runner =
      Task.async(fn ->
        Simulator.run(sim_ctx, mission.id, max_ticks: 900)
      end)

    # Refinement is async under TaskSupervisor — give it up to 30s to land
    found =
      eventually(fn ->
        Enum.any?(GiTF.Skills.all(), &(&1.name == "lockfile-enforcement"))
      end, 30_000)

    # Clean up the runner regardless of assertion outcome
    _ = Task.yield(runner, 5_000) || Task.shutdown(runner, :brutal_kill)

    assert found,
           "expected an auto_drafted skill named 'lockfile-enforcement' to appear in the Archive"

    drafted = Enum.find(GiTF.Skills.all(), &(&1.name == "lockfile-enforcement"))
    assert drafted.source == :auto_drafted
    assert drafted.scope == :global
  end

  # -- Helpers ----------------------------------------------------------------

  defp restore(key, nil), do: Application.delete_env(:gitf, key)
  defp restore(key, value), do: Application.put_env(:gitf, key, value)

  defp eventually(fun, timeout_ms, interval_ms \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline, interval_ms)
  end

  defp do_eventually(fun, deadline, interval_ms) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(interval_ms)
        do_eventually(fun, deadline, interval_ms)
      end
    end
  end

  defp scenario_rules do
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
              "goal_restatement" => "fix bug",
              "external_resource_urls" => [],
              "bug_reproducible" => true,
              "bug_evidence" => "app/main.js:1"
            })
          )
      },

      # Impl makes some change (doesn't actually matter what — the
      # validator will say fail below, triggering refinement).
      %{
        match: ~r/Implement:/i,
        consume: false,
        response: ScriptedLLMClient.ok_text("Did the thing."),
        side_effect: fn ->
          case GiTF.Archive.filter(:missions, fn m ->
                 m[:status] not in ["completed", "failed", "closed"]
               end) do
            [m | _] ->
              try do
                Simulator.simulate_impl_commit(
                  m.id,
                  [{"app/main.js", "// changed\n"}],
                  "sim: impl"
                )
              rescue
                _ -> :ok
              end

            _ ->
              :ok
          end
        end
      },

      # Validation returns fail with a specific gap the refiner will turn
      # into a skill draft.
      %{
        match: ~r/# Validation Phase/,
        consume: false,
        response:
          ScriptedLLMClient.ok_text(
            ScriptedLLMClient.json_artifact(%{
              "requirements_met" => [],
              "gaps" => ["Lockfile was not committed after manifest change"],
              "overall_verdict" => "fail",
              "summary" => "missing lockfile"
            })
          )
      },

      # Refiner: proposes a draft_new skill
      %{
        match: ~r/You are maintaining a library of reusable skills/,
        consume: false,
        response:
          ScriptedLLMClient.ok_text(~s({
            "action":"draft_new",
            "target_skill_id":null,
            "name":"lockfile-enforcement",
            "description":"Always commit the lockfile when the manifest changes",
            "body":"---\\nname: lockfile-enforcement\\ndescription: Always commit the lockfile when the manifest changes\\n---\\nWhen package.json or similar manifest files are edited, the matching lockfile must be regenerated and committed in the same change.",
            "scope":"global",
            "rationale":"validator flagged missing lockfile on manifest change"
          }))
      },

      # Critic: approves
      %{
        match: ~r/You are a critic reviewing a proposed new skill/,
        consume: false,
        response:
          ScriptedLLMClient.ok_text(
            "VERDICT: approve | REASON: Generalizable and actionable rule"
          )
      },

      # Fix-op responses (fix loop may fire; keep the pipeline unblocked)
      %{
        match: ~r/## Validation Feedback/,
        consume: false,
        response: ScriptedLLMClient.ok_text("Tried fix.")
      },

      simplify_rule("Code Reuse Review"),
      simplify_rule("Code Quality Review"),
      simplify_rule("(?:Code\\s)?Efficiency Review"),

      %{
        match: ~r/# Final Scoring/,
        consume: false,
        response:
          ScriptedLLMClient.ok_text(
            ScriptedLLMClient.json_artifact(%{
              "overall_score" => 40,
              "dimension_scores" => %{
                "final_output" => 40,
                "trajectory" => 40,
                "tool_usage" => 40,
                "safety_alignment" => 40
              },
              "summary" => "failed"
            })
          )
      }
    ]
  end

  defp simplify_rule(focus_pattern) do
    %{
      match: ~r/# #{focus_pattern}/,
      consume: false,
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
