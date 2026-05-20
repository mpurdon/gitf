defmodule GiTF.Simulator.ParallelImplTournamentTest do
  @moduledoc """
  End-to-end simulation of the parallel-impl tournament feature
  (audit gap #7). With `parallel_impl_attempts > 1`, the orchestrator
  spawns N impl ghosts, runs validation per variant, and promotes the
  winning variant's artifact to the canonical `"validation"` key before
  advancing to simplify/scoring.

  These tests lock in:

    * `mission.impl_variants` is populated with variant ids
    * each impl op carries its `variant` tag
    * validation artifacts land under `validation_<variant>`
    * `Tournament.resolve/1` picks a winner and stamps
      `mission.winning_variant`
    * the canonical `"validation"` artifact equals the winner's artifact
    * downstream phases see only the winner (no double-publish)

  Without this coverage, a regression in
  `Phases.Validation.promote_winning_variant/2` (recent bug: write order
  could leave the canonical artifact missing on crash) or in
  `Tournament.resolve/1` would slip through the unit suite.

  ## Known flake (cross-test contamination)

  This test depends on a clean Major + GhostWorker supervision state.
  When ExUnit orders it after `StoreCase`-using tests that thrash the
  Archive (notably `test/gitf/phases/validation_test.exs`), a per-variant
  validation op can remain `"assigned"` with no worker process attached,
  stalling the mission at validation.

  Passes reliably in isolation (`mix test
  test/simulator/parallel_impl_tournament_test.exs`) and when the
  simulator dir runs as a self-contained block. Flakes on roughly 20%
  of full-suite seeds; the underlying isolation gap affects all
  simulator tests but only surfaces here because tournament mode
  spawns more concurrent ghosts than any other scenario.
  """
  use ExUnit.Case, async: false

  alias GiTF.Test.{ScriptedLLMClient, Simulator}

  @moduletag :simulator
  @moduletag timeout: 300_000

  setup do
    prior_attempts = Application.get_env(:gitf, :parallel_impl_attempts)
    Application.put_env(:gitf, :parallel_impl_attempts, 2)

    on_exit(fn ->
      if prior_attempts do
        Application.put_env(:gitf, :parallel_impl_attempts, prior_attempts)
      else
        Application.delete_env(:gitf, :parallel_impl_attempts)
      end
    end)

    :ok
  end

  describe "two variants spawned, validated, and winner promoted" do
    test "mission completes with winner-only canonical artifact" do
      {:ok, sim_ctx} =
        Simulator.setup_scenario(
          rules: tournament_rules(),
          sector_name: "tournament-#{:erlang.unique_integer([:positive])}",
          files: %{"app/main.js" => "// initial\n"}
        )

      on_exit(fn -> Simulator.reset!(sim_ctx) end)

      {:ok, mission} = Simulator.create_mission(sim_ctx, goal: "Tournament E2E test")

      # Attach an idempotent per-variant commit hook. Both Implement:
      # rules invoke it so a missed shell on the first call (second
      # ghost still in :provision) is recovered on the second.
      attach_variant_commit_hook(mission.id)

      {:ok, outcome} = Simulator.run(sim_ctx, mission.id, max_ticks: 400)
      mission_final = outcome.mission

      assert mission_final.impl_variants == ["v1", "v2"],
             "expected impl_variants stamped: #{inspect(mission_final.impl_variants)}"

      variant_tags =
        mission_final.ops
        |> Enum.reject(& &1[:phase_job])
        |> Enum.map(& &1[:variant])
        |> Enum.sort()

      assert variant_tags == ["v1", "v2"],
             "expected impl ops tagged v1 + v2: #{inspect(variant_tags)}"

      v1_artifact = GiTF.Missions.get_artifact(mission.id, "validation_v1")
      v2_artifact = GiTF.Missions.get_artifact(mission.id, "validation_v2")

      assert is_map(v1_artifact), "validation_v1 artifact missing"
      assert is_map(v2_artifact), "validation_v2 artifact missing"

      # Equal verdicts → tiebreaker (lower variant index) → v1 wins.
      # Merit-based tiebreaking is covered exhaustively in
      # test/gitf/tournament_test.exs; this test locks the wiring.
      assert mission_final.winning_variant == "v1",
             "expected v1 to win by tiebreaker: " <>
               "got #{inspect(mission_final.winning_variant)}"

      canonical = GiTF.Missions.get_artifact(mission.id, "validation")

      # Canonical is a superset of the winner (downstream phases like
      # Validation.handle_result/1 enrich it with `requires_approval`).
      # The winner's keys must survive verbatim.
      assert is_map(canonical), "canonical validation artifact missing"

      Enum.each(v1_artifact, fn {k, v} ->
        assert Map.get(canonical, k) == v,
               "canonical[#{inspect(k)}] = #{inspect(Map.get(canonical, k))} " <>
                 "does not match winner v1's #{inspect(v)}"
      end)

      assert outcome.status == "completed",
             "mission stalled: phases=#{inspect(outcome.phases_seen)} " <>
               "status=#{outcome.status}"
    end
  end

  # ---------------------------------------------------------------------------
  # Variant commit hook
  # ---------------------------------------------------------------------------

  # Builds an idempotent side-effect that commits a `tournament-<variant>.txt`
  # marker to each variant's shell worktree. Attaches it to both Implement:
  # rules so whichever call lands second sees both shells and tops up any
  # variant that the first call missed (race with second ghost's
  # `handle_continue(:provision, _)`).
  defp attach_variant_commit_hook(mission_id) do
    hook = fn -> ensure_variant_commits(mission_id) end

    %{rules: rules} = :sys.get_state(ScriptedLLMClient)

    updated =
      Enum.map(rules, fn
        %{match: %Regex{source: "Implement:"}} = rule ->
          previous = Map.get(rule, :side_effect)

          chained = fn ->
            if is_function(previous, 0), do: previous.()
            hook.()
          end

          Map.put(rule, :side_effect, chained)

        other ->
          other
      end)

    {:ok, _} = ScriptedLLMClient.start_scenario(updated)
    :ok
  end

  defp ensure_variant_commits(mission_id) do
    GiTF.Ops.list(mission_id: mission_id)
    |> Enum.filter(fn op ->
      op[:phase_job] in [nil, false] and is_binary(op[:variant]) and is_binary(op[:ghost_id])
    end)
    |> Enum.each(&commit_variant_marker/1)
  end

  defp commit_variant_marker(op) do
    variant = op[:variant]

    with %{shell_id: sid} when is_binary(sid) <- GiTF.Archive.get(:ghosts, op.ghost_id),
         %{worktree_path: path} when is_binary(path) <- GiTF.Archive.get(:shells, sid) do
      marker = Path.join(path, "tournament-#{variant}.txt")

      unless File.exists?(marker) do
        File.write!(marker, "variant #{variant}\n")

        {_, 0} =
          System.cmd("/usr/bin/git", ["add", "-A"], cd: path, stderr_to_stdout: true)

        {_, code} =
          System.cmd(
            "/usr/bin/git",
            ["-c", "user.email=sim@test", "-c", "user.name=Simulator",
             "commit", "-m", "sim: variant #{variant}"],
            cd: path,
            stderr_to_stdout: true
          )

        # `git commit` exits non-zero on an empty index; we tolerate that
        # because a later Impl: call may re-enter the hook against the
        # same shell after the previous call already committed.
        _ = code
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Rule sets
  # ---------------------------------------------------------------------------

  defp tournament_rules do
    [
      triage_simple_rule(),
      impl_rule(),
      impl_rule(),
      validation_pass_rule(),
      validation_pass_rule(),
      simplify_reuse_rule(),
      simplify_quality_rule(),
      simplify_efficiency_rule(),
      scoring_rule()
    ]
  end

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
            "goal_restatement" => "Tournament integration test",
            "external_resource_urls" => [],
            "bug_reproducible" => true,
            "bug_evidence" => "app/main.js:1"
          })
        )
    }
  end

  defp impl_rule do
    %{match: ~r/Implement:/, response: ScriptedLLMClient.ok_text("Done.")}
  end

  defp validation_pass_rule do
    %{
      match: ~r/# Validation Phase/,
      response:
        ScriptedLLMClient.ok_text(
          ScriptedLLMClient.json_artifact(%{
            "requirements_met" => [
              %{"req_id" => "FR-1", "met" => true, "evidence" => "marker committed"}
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
