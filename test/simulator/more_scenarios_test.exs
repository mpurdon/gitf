defmodule GiTF.Simulator.MoreScenariosTest do
  @moduledoc """
  Additional failure-injection scenarios. Each test exercises ONE mode
  of failure from the hardening audit. Red scenarios document known
  bugs; green scenarios are reliability gates.
  """
  use ExUnit.Case, async: false

  alias GiTF.Test.{ScriptedLLMClient, Simulator}

  @moduletag :simulator

  # ---------------------------------------------------------------------------
  # Triage short-circuit scenarios
  # ---------------------------------------------------------------------------

  describe "triage bug_reproducible=false, strong evidence" do
    test "short-circuits the pipeline via complete_quest_no_work_needed" do
      {:ok, sim_ctx} = setup_scenario(rules_triage_not_reproducible_strong())
      on_exit(fn -> Simulator.reset!(sim_ctx) end)

      {:ok, mission} = Simulator.create_mission(sim_ctx, goal: "Fix bug that is already fixed")
      {:ok, outcome} = Simulator.run(sim_ctx, mission.id, max_ticks: 60)

      # Should complete WITHOUT ever running impl/validation/etc.
      assert outcome.status == "completed",
             "expected quick no-work-needed completion, got: #{inspect(outcome.status)}"

      phases = outcome.phases_seen

      refute "implementation" in phases,
             "pipeline should have short-circuited, but reached implementation: #{inspect(phases)}"

      preflight = GiTF.Missions.get_artifact(mission.id, "preflight") || %{}

      assert preflight["resolution"] == "no_work_needed",
             "expected preflight artifact recording no-work-needed: #{inspect(preflight)}"
    end
  end

  describe "triage bug_reproducible=false, weak evidence" do
    test "refuses to short-circuit; runs the full pipeline" do
      {:ok, sim_ctx} = setup_scenario(rules_triage_not_reproducible_weak())
      on_exit(fn -> Simulator.reset!(sim_ctx) end)

      attach_commit_hook(sim_ctx)
      {:ok, mission} = Simulator.create_mission(sim_ctx, goal: "Ambiguous issue")
      {:ok, outcome} = Simulator.run(sim_ctx, mission.id, max_ticks: 300)

      phases = outcome.phases_seen

      # Must NOT short-circuit — weak evidence falls through to pipeline.
      assert "implementation" in phases,
             "weak evidence should have forced the pipeline to run impl; phases: #{inspect(phases)}"

      # And the mission must ultimately succeed or fail cleanly, not stall.
      assert outcome.status in ["completed", "failed"],
             "mission stuck: #{inspect(outcome)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Validator failure modes
  # ---------------------------------------------------------------------------

  describe "validator keeps hallucinating fail after every fix attempt" do
    test "fix-loop terminates after max attempts, does not spin forever" do
      {:ok, sim_ctx} = setup_scenario(rules_validator_always_fails())
      on_exit(fn -> Simulator.reset!(sim_ctx) end)

      attach_commit_hook(sim_ctx)
      {:ok, mission} = Simulator.create_mission(sim_ctx, goal: "Validator keeps saying fail")

      # Cap ticks so a spin-forever loop is observable as a timeout
      # rather than hanging the test suite. Fix-loop involves several
      # ghost spawns + retries, so this budget is generous.
      result = Simulator.run(sim_ctx, mission.id, max_ticks: 900)

      case result do
        {:ok, outcome} ->
          assert outcome.status == "failed",
                 "hallucinating validator should exhaust fix attempts and fail: " <>
                   inspect(outcome.status)

        {:timeout, info} ->
          flunk(
            "fix-loop did not terminate within 400 ticks — " <>
              "validator regression allows spin: #{inspect(info)}"
          )
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Rate limit / provider transient errors
  # ---------------------------------------------------------------------------

  describe "provider transient error (rate-limit-style)" do
    test "triage recovers via retry when the first call returns a transient error" do
      counter = :counters.new(1, [:atomics])

      {:ok, sim_ctx} = setup_scenario(rules_triage_transient_first_call(counter))
      on_exit(fn -> Simulator.reset!(sim_ctx) end)

      attach_commit_hook(sim_ctx)
      {:ok, mission} = Simulator.create_mission(sim_ctx, goal: "Transient error test")

      result = Simulator.run(sim_ctx, mission.id, max_ticks: 300)

      # Both the failed first triage and the successful second should
      # have consulted the mock.
      assert :counters.get(counter, 1) >= 2,
             "expected at least two triage LLM calls (first transient, second OK): " <>
               "counter=#{:counters.get(counter, 1)}"

      case result do
        {:ok, outcome} ->
          assert outcome.status in ["completed", "failed"],
                 "mission stuck after transient recovery: #{inspect(outcome)}"

        {:timeout, info} ->
          flunk("transient-retry scenario stalled: #{inspect(info)}")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp setup_scenario(rules) do
    Simulator.setup_scenario(
      rules: rules,
      sector_name: "more-#{:erlang.unique_integer([:positive])}",
      files: %{"app/main.js" => "// initial\n"}
    )
  end

  # Attach the impl-commit side_effect to any rule whose prompt pattern
  # drives an impl/fix ghost — impl ops (`Implement:`) and validation
  # fix-ops (`## Validation Feedback`). Call BEFORE Simulator.run.
  defp attach_commit_hook(sim_ctx) do
    hook = Simulator.impl_commit_hook(sim_ctx.sector.id, [{"app/main.js", "// fixed\n"}])

    %{rules: rules} = :sys.get_state(ScriptedLLMClient)

    commit_match_sources = ["Implement:", "## Validation Feedback"]

    updated =
      Enum.map(rules, fn
        %{match: %Regex{source: src}} = r ->
          if src in commit_match_sources do
            previous = Map.get(r, :side_effect)

            chained = fn ->
              if is_function(previous, 0), do: previous.()
              hook.()
            end

            Map.put(r, :side_effect, chained)
          else
            r
          end

        other ->
          other
      end)

    {:ok, _} = ScriptedLLMClient.start_scenario(updated)
    :ok
  end

  # -- Rule sets -------------------------------------------------------------

  defp rules_triage_not_reproducible_strong do
    [
      %{
        match: ~r/# Triage Phase/,
        response:
          ScriptedLLMClient.ok_text(
            ScriptedLLMClient.json_artifact(%{
              "complexity" => "simple",
              "skip_flags" => %{},
              "goal_restatement" => "Already-fixed",
              "external_resource_urls" => [],
              "bug_reproducible" => false,
              # Strong evidence: a SHA citation satisfies
              # Triage.strong_no_work_evidence?/1
              "bug_evidence" =>
                "Searched app/main.js — bad state is NOT present. " <>
                  "Already fixed in commit abc1234."
            })
          )
      }
    ]
  end

  defp rules_triage_not_reproducible_weak do
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
              "goal_restatement" => "Ambiguous issue",
              "external_resource_urls" => [],
              "bug_reproducible" => false,
              # Weak evidence — prose only, no SHA / file:line / test
              "bug_evidence" => "I could not reproduce this on the latest main"
            })
          )
      },
      impl_text_rule(),
      validation_pass_rule(),
      simplify_reuse_rule(),
      simplify_quality_rule(),
      simplify_efficiency_rule(),
      scoring_rule()
    ]
  end

  defp rules_validator_always_fails do
    [
      triage_simple_rule(),
      impl_text_rule(),

      # Every validation call says fail with the same gap — worst case for
      # the fix loop. Use consume:false so every retry hits this.
      %{
        match: ~r/# Validation Phase/,
        consume: false,
        response:
          ScriptedLLMClient.ok_text(
            ScriptedLLMClient.json_artifact(%{
              "requirements_met" => [],
              "gaps" => ["The fix is not present (false negative from hallucinating validator)"],
              "overall_verdict" => "fail",
              "summary" => "fail"
            })
          )
      },

      # Fix-op prompts start with "## Validation Feedback". Give them a
      # text response that lets the worker treat the op as "done" (so long
      # as a commit happens — attach_commit_hook/1 wires the commit hook
      # here too).
      %{
        match: ~r/## Validation Feedback/,
        consume: false,
        response: ScriptedLLMClient.ok_text("Fix attempted.")
      }
    ]
  end

  defp rules_triage_transient_first_call(counter) do
    bump = fn -> :counters.add(counter, 1, 1) end

    [
      # First triage call: transient-looking error (rate-limit-ish).
      %{
        match: ~r/# Triage Phase/,
        consume: true,
        response: {:error, {:api_error, :empty_response}},
        side_effect: bump
      },

      # Second triage call: normal success. Worker retries same-model on
      # :empty_response, so this is the retry.
      %{
        match: ~r/# Triage Phase/,
        consume: true,
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
          ),
        side_effect: bump
      },
      impl_text_rule(),
      validation_pass_rule(),
      simplify_reuse_rule(),
      simplify_quality_rule(),
      simplify_efficiency_rule(),
      scoring_rule()
    ]
  end

  # -- Shared phase rules ----------------------------------------------------

  defp triage_simple_rule do
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
    }
  end

  defp impl_text_rule do
    %{match: ~r/Implement:/, response: ScriptedLLMClient.ok_text("Done.")}
  end

  defp validation_pass_rule do
    %{
      match: ~r/# Validation Phase/,
      response:
        ScriptedLLMClient.ok_text(
          ScriptedLLMClient.json_artifact(%{
            "requirements_met" => [
              %{"req_id" => "FR-1", "met" => true, "evidence" => "ok"}
            ],
            "gaps" => [],
            "overall_verdict" => "pass",
            "summary" => "ok"
          })
        )
    }
  end

  defp simplify_reuse_rule do
    %{
      match: ~r/# Code Reuse Review/,
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

  defp simplify_quality_rule do
    %{
      match: ~r/# Code Quality Review/,
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

  defp simplify_efficiency_rule do
    %{
      match: ~r/# (?:Code\s)?Efficiency Review/,
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

  defp scoring_rule do
    %{
      match: ~r/# Final Scoring/,
      response:
        ScriptedLLMClient.ok_text(
          ScriptedLLMClient.json_artifact(%{
            "overall_score" => 90,
            "dimension_scores" => %{
              "final_output" => 95,
              "trajectory" => 90,
              "tool_usage" => 85,
              "safety_alignment" => 95
            },
            "summary" => "ok"
          })
        )
    }
  end
end
