defmodule GiTF.Simulator.FailureScenariosTest do
  @moduledoc """
  Failure-injection scenarios for the pipeline. Each test exercises ONE
  specific failure mode identified in the hardening audit and asserts the
  observable outcome.

  These are the reliability gates: if a scenario here regresses, something
  in the orchestration machinery has silently degraded.
  """
  use ExUnit.Case, async: false

  alias GiTF.Test.{ScriptedLLMClient, Simulator}

  @moduletag :simulator

  describe "publish failure must not be masked as success" do
    test "mission with failed PR creation records pr_failed in publish artifact" do
      # Sector strategy = pr_branch + no `origin` remote → `gh pr create`
      # fails (no remote to push to). Publish artifact must reflect the
      # failure rather than being absent / faked.
      {:ok, sim_ctx} = setup_with_rules(fast_path_rules(sector_id_fn: &sector_id/0))

      on_exit(fn -> Simulator.reset!(sim_ctx) end)

      GiTF.Archive.update(:sectors, sim_ctx.sector.id, fn s ->
        Map.put(s, :sync_strategy, "pr_branch")
      end)

      # Commit hook now captures the known sector id
      update_impl_rule_with_hook(sim_ctx, "app/main.js", "// fixed\n")

      {:ok, mission} = Simulator.create_mission(sim_ctx, goal: "Publish-fail scenario")

      {:ok, outcome} = Simulator.run(sim_ctx, mission.id, max_ticks: 300)

      publish_artifact = GiTF.Missions.get_artifact(mission.id, "publish") || %{}

      refute publish_artifact["pr_url"],
             "publish artifact claims a PR URL when no remote is configured: " <>
               inspect(publish_artifact)

      assert publish_artifact["status"] in ["pr_failed", "push_failed", "skipped"],
             "publish artifact should record the failure: #{inspect(publish_artifact)}"

      # Critical invariant: if publish failed to produce its deliverable
      # (the PR or the pushed main), the MISSION must be marked failed —
      # never "completed" with a missing PR. This is the core bug the
      # audit flagged.
      if publish_artifact["status"] in ["pr_failed", "push_failed"] do
        assert outcome.status == "failed",
               "Publish failed but mission is #{inspect(outcome.status)} — " <>
                 "silent-success-on-publish-failure regression"
      end
    end
  end

  describe "empty LLM response must retry, not silently fail" do
    test "impl ghost retries after an :empty_response and eventually completes" do
      counter = :counters.new(1, [:atomics])

      {:ok, sim_ctx} = setup_with_rules(rules_with_empty_impl_first(counter))

      on_exit(fn -> Simulator.reset!(sim_ctx) end)

      # Arm the SECOND impl rule with a commit side-effect so once retry
      # succeeds, the worker sees files_changed > 0.
      arm_second_impl_rule_with_commit(sim_ctx, "app/main.js", "// fixed\n")

      {:ok, mission} = Simulator.create_mission(sim_ctx, goal: "Empty-response retry test")

      {:ok, outcome} = Simulator.run(sim_ctx, mission.id, max_ticks: 300)

      assert :counters.get(counter, 1) >= 2,
             "expected impl LLM to be called at least twice (first empty, second OK); " <>
               "counter=#{:counters.get(counter, 1)}"

      assert outcome.status == "completed",
             "mission didn't complete despite retry: #{inspect(outcome, pretty: true, limit: 20)}"
    end
  end

  describe "scenario authoring errors are caught, not silently swallowed" do
    test "unmatched LLM prompts bump the unmatched counter" do
      {:ok, sim_ctx} = setup_with_rules([])

      on_exit(fn -> Simulator.reset!(sim_ctx) end)

      {:ok, mission} =
        Simulator.create_mission(sim_ctx, goal: "Scenario with empty rules")

      _ = Simulator.run(sim_ctx, mission.id, max_ticks: 40)

      assert ScriptedLLMClient.unmatched_count() > 0,
             "expected at least one unmatched LLM call to surface as a simulator signal"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp setup_with_rules(rules) do
    Simulator.setup_scenario(
      rules: rules,
      sector_name: "fail-#{:erlang.unique_integer([:positive])}",
      files: %{"app/main.js" => "// initial\n"}
    )
  end

  # Updates the existing scripted scenario: finds the Implement rule and
  # attaches an auto-resolving commit hook. Must be called AFTER
  # Simulator.setup_scenario / before Simulator.run.
  defp update_impl_rule_with_hook(sim_ctx, rel_path, content) do
    hook = Simulator.impl_commit_hook(sim_ctx.sector.id, [{rel_path, content}])

    %{rules: rules} = :sys.get_state(ScriptedLLMClient)

    updated =
      Enum.map(rules, fn
        %{match: %Regex{} = re} = rule ->
          if Regex.source(re) == "Implement:" do
            Map.put(rule, :side_effect, hook)
          else
            rule
          end

        other ->
          other
      end)

    {:ok, _} = ScriptedLLMClient.start_scenario(updated)
    :ok
  end

  defp arm_second_impl_rule_with_commit(sim_ctx, rel_path, content) do
    hook = Simulator.impl_commit_hook(sim_ctx.sector.id, [{rel_path, content}])
    %{rules: rules} = :sys.get_state(ScriptedLLMClient)

    # Walk the rules and compose: the LAST Implement-matching rule gets
    # its existing side_effect chained with the commit hook. Preserves
    # the bump-counter behavior set by the scenario.
    impl_indices =
      rules
      |> Enum.with_index()
      |> Enum.filter(fn {rule, _i} ->
        match?(%{match: %Regex{source: "Implement:"}}, rule)
      end)
      |> Enum.map(fn {_, i} -> i end)

    target_idx = List.last(impl_indices)

    updated =
      Enum.with_index(rules)
      |> Enum.map(fn {rule, i} ->
        if i == target_idx do
          previous = Map.get(rule, :side_effect)

          chained = fn ->
            if is_function(previous, 0), do: previous.()
            hook.()
          end

          Map.put(rule, :side_effect, chained)
        else
          rule
        end
      end)

    {:ok, _} = ScriptedLLMClient.start_scenario(updated)
    :ok
  end

  # -- Rule sets --------------------------------------------------------------

  # Fast-path rules that carry a mission through simplify + publish.
  # The `sector_id_fn` is unused at this layer (the commit hook attaches
  # later in the test body) — we keep the signature uniform.
  defp fast_path_rules(_opts) do
    [
      triage_simple_rule(),
      impl_text_rule(),
      validation_pass_rule(),
      simplify_reuse_rule(),
      simplify_quality_rule(),
      simplify_efficiency_rule(),
      scoring_rule()
    ]
  end

  defp rules_with_empty_impl_first(counter) do
    bump = fn -> :counters.add(counter, 1, 1) end

    [
      triage_simple_rule(),

      # First impl call: empty response → worker should retry
      %{
        match: ~r/Implement:/,
        response: ScriptedLLMClient.empty_response(),
        consume: true,
        side_effect: bump
      },

      # Second impl call: normal response; hook gets attached later to commit
      %{
        match: ~r/Implement:/,
        response: ScriptedLLMClient.ok_text("Fixed."),
        consume: true,
        side_effect: bump
      },

      validation_pass_rule(),
      simplify_reuse_rule(),
      simplify_quality_rule(),
      simplify_efficiency_rule(),
      scoring_rule()
    ]
  end

  # Unused placeholder kept to avoid "unused variable" warnings on
  # sector_id_fn. Real scenarios fetch the sector via sim_ctx.
  defp sector_id, do: nil

  # -- Individual phase rules -------------------------------------------------

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
            "goal_restatement" => "Sim goal",
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
              %{"req_id" => "FR-1", "met" => true, "evidence" => "diff shows change"}
            ],
            "gaps" => [],
            "overall_verdict" => "pass",
            "summary" => "OK"
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
