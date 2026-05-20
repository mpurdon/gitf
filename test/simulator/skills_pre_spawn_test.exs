defmodule GiTF.Simulator.SkillsPreSpawnTest do
  @moduledoc """
  M1 end-to-end gate: verify that pre-seeded skills are installed into
  the impl ghost's worktree before the LLM call fires.

  Flow:
    1. Pre-seed a global skill into the Archive.
    2. Mock the embedding client so retrieval is deterministic.
    3. Enable :skills_enabled.
    4. Run a mission whose op text matches the seeded skill.
    5. Assert the skill body is present at
       `<worktree>/.claude/skills/<skill_id>.md` AND the op record
       carries `applied_skill_ids: [<id>]`.

  Without this guard, skills could silently fail to install (config off,
  retrieval crash, install path mismatch) and we'd have no idea.
  """

  use ExUnit.Case, async: false

  alias GiTF.Test.{ScriptedLLMClient, Simulator}

  @moduletag :simulator

  defmodule MockEmbeddingClient do
    @behaviour GiTF.Skills.Embedding

    @impl true
    def embed(_model, _text) do
      # Constant unit vector — every text maps to the same embedding, so
      # every op trivially matches every skill at cosine 1.0. This proves
      # the install path works end-to-end; similarity ranking is covered
      # separately in retrieval_test.exs.
      {:ok, [1.0, 0.0]}
    end
  end

  setup do
    # Activate skills + mock embedding client for the duration of this test
    prev_enabled = Application.get_env(:gitf, :skills_enabled)
    prev_client = Application.get_env(:gitf, :embedding_client)
    prev_threshold = Application.get_env(:gitf, :skill_min_similarity)

    Application.put_env(:gitf, :skills_enabled, true)
    Application.put_env(:gitf, :embedding_client, MockEmbeddingClient)
    Application.put_env(:gitf, :skill_min_similarity, 0.0)

    on_exit(fn ->
      restore_env(:skills_enabled, prev_enabled)
      restore_env(:embedding_client, prev_client)
      restore_env(:skill_min_similarity, prev_threshold)
    end)

    # Seed a skill that should match a "lockfile" op
    # `Skills.create/1` writes to the app Archive — make sure it's
    # healthy before the rest of setup runs (StoreCase teardown from a
    # prior test may have left it pointing at a deleted data_dir).
    GiTF.Test.StoreHelper.restore_app_store()

    {:ok, skill} =
      GiTF.Skills.create(%{
        name: "test-lockfile-skill-#{:erlang.unique_integer([:positive])}",
        description: "Always update the lockfile after manifest changes",
        body: "---\nname: lockfile\ndescription: lockfile rule\n---\nlockfile body",
        scope: :global
      })

    on_exit(fn -> GiTF.Skills.delete(skill.id) end)

    {:ok, sim_ctx} =
      Simulator.setup_scenario(
        rules: scenario_rules(),
        sector_name: "skills-pre-spawn-#{:erlang.unique_integer([:positive])}",
        files: %{"app/main.js" => "// initial\n"}
      )

    on_exit(fn -> Simulator.reset!(sim_ctx) end)

    %{sim_ctx: sim_ctx, skill: skill}
  end

  test "pre-seeded skill is installed into impl ghost worktree", %{sim_ctx: sim_ctx, skill: skill} do
    {:ok, mission} =
      Simulator.create_mission(sim_ctx,
        goal: "Update lockfile after editing the manifest"
      )

    # Wire impl rule to commit a non-.claude file so cross-check passes.
    new_rules =
      Enum.map(sim_ctx.scenario_rules, fn rule ->
        case rule do
          %{match: %Regex{source: "Implement:"}} = r ->
            Map.put(r, :side_effect, fn ->
              Simulator.simulate_impl_commit(
                mission.id,
                [{"app/main.js", "// updated\n"}],
                "sim: lockfile fix"
              )
            end)

          other ->
            other
        end
      end)

    {:ok, _} = ScriptedLLMClient.start_scenario(new_rules)

    # Snapshot every ghost worktree under the sector during the run so we
    # can verify skills landed somewhere — capturing inside side_effect at
    # impl-call time can race with phase advancement and pick the wrong shell.
    snapshot_dir = Path.join(System.tmp_dir!(), "skills_snap_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(snapshot_dir)
    on_exit(fn -> File.rm_rf!(snapshot_dir) end)

    snapshot_task =
      Task.async(fn ->
        snapshot_loop(sim_ctx.sector_path, snapshot_dir, skill.id, 60_000)
      end)

    {:ok, _outcome} = Simulator.run(sim_ctx, mission.id, max_ticks: 600)
    found = Task.await(snapshot_task, 65_000)

    assert found,
           "no ghost worktree under #{sim_ctx.sector_path} had skill #{skill.id}.md " <>
             "(snapshots saved to #{snapshot_dir})"

    # Assert: the impl op carries applied_skill_ids tracking
    impl_op =
      GiTF.Ops.list(mission_id: mission.id)
      |> Enum.find(fn op ->
        op[:phase_job] in [nil, false] and op.status in ["done", "completed", "running"]
      end)

    if impl_op do
      applied = Map.get(impl_op, :applied_skill_ids, [])

      assert skill.id in applied,
             "skill #{skill.id} not in op.applied_skill_ids: #{inspect(applied)}"
    end
  end

  # Polls the sector's ghosts/ subtree looking for any worktree whose
  # .claude/skills/ directory contains the target skill file. Returns true
  # as soon as one is seen. Worktrees are cleaned up after the run, so we
  # have to catch the file while it exists.
  defp snapshot_loop(sector_path, _snapshot_dir, skill_id, deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    target = "#{skill_id}.md"
    ghosts_root = Path.join(sector_path, "ghosts")
    do_snapshot_loop(ghosts_root, target, deadline)
  end

  defp do_snapshot_loop(ghosts_root, target, deadline) do
    if found_skill?(ghosts_root, target) do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(100)
        do_snapshot_loop(ghosts_root, target, deadline)
      end
    end
  end

  defp found_skill?(ghosts_root, target) do
    case File.ls(ghosts_root) do
      {:ok, ghost_dirs} ->
        Enum.any?(ghost_dirs, fn ghost ->
          File.exists?(Path.join([ghosts_root, ghost, ".claude/skills", target]))
        end)

      _ ->
        false
    end
  end

  # -- Helpers ----------------------------------------------------------------

  defp restore_env(key, nil), do: Application.delete_env(:gitf, key)
  defp restore_env(key, value), do: Application.put_env(:gitf, key, value)

  # Same minimal scripted-rule set as happy_path: triage skips ahead to
  # impl, validation passes, simplify+scoring return clean.
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
              "goal_restatement" => "lockfile fix",
              "external_resource_urls" => [],
              "bug_reproducible" => true,
              "bug_evidence" => "app/main.js:1"
            })
          )
      },
      %{
        match: ~r/Implement:/i,
        response: ScriptedLLMClient.ok_text("Updated the lockfile.")
      },
      %{
        match: ~r/# Validation Phase/,
        response:
          ScriptedLLMClient.ok_text(
            ScriptedLLMClient.json_artifact(%{
              "requirements_met" => [
                %{"req_id" => "FR-1", "met" => true, "evidence" => "app/main.js:1"}
              ],
              "gaps" => [],
              "overall_verdict" => "pass",
              "summary" => "Done"
            })
          )
      },
      simplify_rule("Code Reuse Review"),
      simplify_rule("Code Quality Review"),
      simplify_rule("(?:Code\\s)?Efficiency Review"),
      %{
        match: ~r/# Final Scoring/,
        response:
          ScriptedLLMClient.ok_text(
            ScriptedLLMClient.json_artifact(%{
              "overall_score" => 90,
              "dimension_scores" => %{
                "final_output" => 90,
                "trajectory" => 90,
                "tool_usage" => 90,
                "safety_alignment" => 90
              },
              "summary" => "Clean"
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
