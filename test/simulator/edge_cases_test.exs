defmodule GiTF.Simulator.EdgeCasesTest do
  @moduledoc """
  Failure-injection scenarios that go beyond pure LLM mocking — they
  inject database records (costs), kill processes (ghost crash), and
  pre-commit conflicting changes (merge conflict).

  Each test verifies one specific failure mode the audit identified as
  a real production risk.
  """
  use ExUnit.Case, async: false

  alias GiTF.Test.{ScriptedLLMClient, Simulator}

  @moduletag :simulator

  # ---------------------------------------------------------------------------
  # Cost cap
  # ---------------------------------------------------------------------------

  describe "per-mission cost cap" do
    test "mission with tiny cost_cap_usd is force-failed when budget exceeded" do
      {:ok, sim_ctx} =
        Simulator.setup_scenario(
          rules: minimal_rules(),
          sector_name: "cost-#{:erlang.unique_integer([:positive])}",
          files: %{"app/main.js" => "// initial\n"}
        )

      on_exit(fn -> Simulator.reset!(sim_ctx) end)

      {:ok, mission} =
        Simulator.create_mission(sim_ctx,
          goal: "Cost-cap test",
          cost_cap_usd: 0.001
        )

      # Costs.for_quest filters by ghost_id of any op tied to the
      # mission. Pre-create an op + cost record so the filter has
      # something to match BEFORE the orchestrator advances.
      fake_ghost_id = "ghost-cost-prefab-#{:erlang.unique_integer([:positive])}"

      {:ok, fake_op} =
        GiTF.Ops.create(%{
          title: "Cost cap prefab op",
          description: "prefab",
          mission_id: mission.id,
          sector_id: sim_ctx.sector.id,
          phase_job: false
        })

      {:ok, _} =
        GiTF.Archive.update(:ops, fake_op.id, fn o ->
          Map.put(o, :ghost_id, fake_ghost_id)
        end)

      {:ok, _} =
        GiTF.Archive.insert(:costs, %{
          ghost_id: fake_ghost_id,
          mission_id: mission.id,
          sector_id: sim_ctx.sector.id,
          cost_usd: 5.0,
          recorded_at: DateTime.utc_now()
        })

      cost_total = GiTF.Costs.for_quest(mission.id) |> GiTF.Costs.total()

      assert cost_total >= 5.0,
             "cost record didn't land for prefab op; cost_total=#{cost_total}"

      result = Simulator.run(sim_ctx, mission.id, max_ticks: 60)

      outcome =
        case result do
          {:ok, o} -> o
          {:timeout, info} -> info
        end

      assert outcome[:status] == "failed",
             "mission with cost_cap_usd: $0.001 + $#{cost_total} spend should fail, got: " <>
               inspect(outcome[:status])

      {:ok, refreshed} = GiTF.Missions.get(mission.id)
      reason = refreshed[:failure_reason] || ""

      assert reason =~ ~r/budget/i,
             "expected failure_reason mentioning budget, got: #{inspect(reason)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Ghost mid-op crash
  # ---------------------------------------------------------------------------

  describe "ghost worker crashes mid-LLM-call" do
    test "orchestrator detects the crash and retries / fails cleanly" do
      crash_count = :counters.new(1, [:atomics])

      {:ok, sim_ctx} =
        Simulator.setup_scenario(
          rules: rules_with_crashing_impl(crash_count),
          sector_name: "crash-#{:erlang.unique_integer([:positive])}",
          files: %{"app/main.js" => "// initial\n"}
        )

      on_exit(fn -> Simulator.reset!(sim_ctx) end)

      attach_recovery_commit_hook(sim_ctx)

      {:ok, mission} =
        Simulator.create_mission(sim_ctx, goal: "Ghost-crash recovery test")

      result = Simulator.run(sim_ctx, mission.id, max_ticks: 600)

      # The crash side_effect must have actually fired
      assert :counters.get(crash_count, 1) >= 1,
             "expected at least one crash injection, got 0"

      # Orchestrator must reach a terminal state — either a clean retry
      # success or a clean failure. NOT stuck in active.
      case result do
        {:ok, outcome} ->
          assert outcome.status in ["completed", "failed"],
                 "ghost crash left mission stuck in #{inspect(outcome.status)}"

        {:timeout, info} ->
          flunk("ghost crash hung the orchestrator: #{inspect(info)}")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Merge conflict
  # ---------------------------------------------------------------------------

  describe "merge-conflict auto-resolution" do
    test "sync recovers when mission branch already has a conflicting commit" do
      {:ok, sim_ctx} =
        Simulator.setup_scenario(
          rules: minimal_rules(),
          sector_name: "merge-#{:erlang.unique_integer([:positive])}",
          files: %{"app/main.js" => "// original line\n"}
        )

      on_exit(fn -> Simulator.reset!(sim_ctx) end)

      sector_path = sim_ctx.sector_path

      # Hook attaches a commit that touches app/main.js with content A.
      attach_main_js_commit(sim_ctx, "// version A\n")

      {:ok, mission} =
        Simulator.create_mission(sim_ctx, goal: "Merge-conflict recovery test")

      # Pre-commit a CONFLICTING change directly on the sector main
      # AFTER the mission has been created (so the ghost's worktree
      # branches from the original main), but BEFORE the impl ghost
      # commits. The merge step in sync should hit a conflict and the
      # auto-resolution path (`-X theirs`) should resolve it.
      Task.start(fn ->
        # Wait for impl ghost to have made its commit, then drop a
        # conflicting commit on main right before sync runs.
        Process.sleep(2_000)

        {_, 0} =
          System.cmd("/usr/bin/git", ["checkout", "main"],
            cd: sector_path,
            stderr_to_stdout: true
          )

        File.write!(Path.join(sector_path, "app/main.js"), "// version B (conflicting)\n")

        {_, 0} =
          System.cmd("/usr/bin/git", ["add", "app/main.js"],
            cd: sector_path,
            stderr_to_stdout: true
          )

        {_, _} =
          System.cmd(
            "/usr/bin/git",
            [
              "-c",
              "user.email=sim@test",
              "-c",
              "user.name=Sim",
              "commit",
              "-m",
              "competing change on main"
            ],
            cd: sector_path,
            stderr_to_stdout: true
          )
      end)

      result = Simulator.run(sim_ctx, mission.id, max_ticks: 400)

      case result do
        {:ok, outcome} ->
          assert outcome.status in ["completed", "failed"],
                 "merge conflict left mission stuck in #{inspect(outcome.status)}: " <>
                   "phases=#{inspect(outcome.phases_seen)}"

        {:timeout, info} ->
          flunk("merge-conflict scenario stalled: #{inspect(info)}")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp attach_recovery_commit_hook(sim_ctx) do
    hook = Simulator.impl_commit_hook(sim_ctx.sector.id, [{"app/main.js", "// fixed\n"}])

    %{rules: rules} = :sys.get_state(ScriptedLLMClient)

    updated =
      Enum.map(rules, fn
        %{match: %Regex{source: src}} = r when src in ["Implement:", "## Validation Feedback"] ->
          previous = Map.get(r, :side_effect)

          chained = fn ->
            if is_function(previous, 0), do: previous.()
            hook.()
          end

          Map.put(r, :side_effect, chained)

        other ->
          other
      end)

    {:ok, _} = ScriptedLLMClient.start_scenario(updated)
    :ok
  end

  defp attach_main_js_commit(sim_ctx, content) do
    hook = Simulator.impl_commit_hook(sim_ctx.sector.id, [{"app/main.js", content}])

    %{rules: rules} = :sys.get_state(ScriptedLLMClient)

    updated =
      Enum.map(rules, fn
        %{match: %Regex{source: "Implement:"}} = r ->
          Map.put(r, :side_effect, hook)

        other ->
          other
      end)

    {:ok, _} = ScriptedLLMClient.start_scenario(updated)
    :ok
  end

  # -- Rule sets -------------------------------------------------------------

  defp minimal_rules do
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

  defp rules_with_crashing_impl(crash_counter) do
    [
      triage_simple_rule(),

      # First impl: side_effect kills the worker process mid-LLM call.
      # The mock returns OK, but immediately after the response is sent
      # the worker is brutally killed. Orchestrator must detect.
      %{
        match: ~r/Implement:/,
        consume: true,
        response: ScriptedLLMClient.ok_text("Working on it..."),
        side_effect: fn ->
          :counters.add(crash_counter, 1, 1)
          kill_one_active_impl_worker()
        end
      },

      # Subsequent impl calls: normal text response. attach_recovery_commit_hook
      # will arm the commit side_effect on these.
      %{
        match: ~r/Implement:/,
        consume: false,
        response: ScriptedLLMClient.ok_text("Done.")
      },

      # Fix-op responses (validator may say fail after retry; safety net)
      %{
        match: ~r/## Validation Feedback/,
        consume: false,
        response: ScriptedLLMClient.ok_text("Fixed.")
      },
      validation_pass_rule(),
      simplify_reuse_rule(),
      simplify_quality_rule(),
      simplify_efficiency_rule(),
      scoring_rule()
    ]
  end

  defp kill_one_active_impl_worker do
    # Find a non-phase ghost in working state and kill it.
    candidate =
      GiTF.Archive.all(:ghosts)
      |> Enum.filter(fn g -> g[:status] in ["working", "running"] end)
      |> List.first()

    if candidate do
      case GiTF.Ghost.Worker.lookup(candidate.id) do
        {:ok, pid} when is_pid(pid) ->
          Process.exit(pid, :kill)

        _ ->
          :ok
      end
    end
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
            "requirements_met" => [%{"req_id" => "FR-1", "met" => true, "evidence" => "ok"}],
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
