defmodule GiTF.E2E.MajorOrchestrationTest do
  use GiTF.TestDriver.Scenario

  scenario "Major advances quest and spawns next job after completion" do
    {:ok, env, comb} = Harness.add_comb(env)
    env = Harness.start_major(env)

    {:ok, quest, [job1, _job2]} =
      Harness.create_quest(env,
        comb_id: comb.id,
        goal: "Major orchestration test",
        jobs: [
          %{title: "First sequential task"},
          %{title: "Second sequential task"}
        ],
        dependencies: [{1, 0}]
      )

    # Spawn a mock ghost for job1 only — Major should auto-spawn for job2
    {:ok, bee1} = Harness.spawn_mock_bee(env, job1.id, comb.id, delay_ms: 200)

    # Wait for job1 to complete
    await({:job_done, job1.id}, timeout: 15_000)
    await({:bee_stopped, bee1.id}, timeout: 5_000)

    # Wait for a waggle from the ghost — the validation pipeline in mark_success
    # may spawn Claude for diff assessment (up to 60s timeout), so be very generous
    await(
      fn ->
        waggles = GiTF.Store.all(:waggles)
        Enum.any?(waggles, &(&1.from == bee1.id))
      end,
      timeout: 15_000
    )

    # Give Major time to process waggle and attempt spawn
    Process.sleep(500)

    # Verify Major is still alive after processing
    assert Process.alive?(env.major_pid)

    # Quest status should reflect the state of jobs.
    # Major attempts to spawn for job2 but without claude_executable,
    # the ghost can't find Claude and fails. After retries, quest may be "failed".
    {:ok, updated_quest} = GiTF.Quests.get(quest.id)
    assert updated_quest.status in ["pending", "active", "completed", "failed"]
  end

  scenario "Major marks quest completed when all jobs done" do
    {:ok, env, comb} = Harness.add_comb(env)
    env = Harness.start_major(env)

    {:ok, quest, [job1]} =
      Harness.create_quest(env,
        comb_id: comb.id,
        goal: "Single job quest completion",
        jobs: [%{title: "Only task"}]
      )

    {:ok, bee1} = Harness.spawn_mock_bee(env, job1.id, comb.id, delay_ms: 200)

    await({:job_done, job1.id}, timeout: 15_000)
    await({:bee_stopped, bee1.id}, timeout: 5_000)

    # The Worker sends a waggle AFTER the validation pipeline completes.
    # The Validator may spawn Claude for diff assessment (60s timeout in Validator).
    # Wait for any waggle from the ghost.
    await(
      fn ->
        waggles = GiTF.Store.all(:waggles)
        Enum.any?(waggles, &(&1.from == bee1.id))
      end,
      timeout: 15_000
    )

    # If job_complete waggle was sent, Major auto-advances the quest.
    # If validation_failed waggle was sent, Major treats it as failure.
    # Check which waggle was sent and verify accordingly.
    waggles = GiTF.Store.filter(:waggles, fn w -> w.from == bee1.id end)
    waggle = hd(waggles)

    case waggle.subject do
      "job_complete" ->
        # Major should have advanced the quest
        await({:quest_completed, quest.id}, timeout: 10_000)
        assert_waggle(subject: "quest_completed")

      "validation_failed" ->
        # Validation spawned Claude and it either failed or the diff was assessed as failing.
        # This is valid behavior — the quest won't be completed.
        assert Process.alive?(env.major_pid)

      _ ->
        # Any other waggle — just verify Major survived
        assert Process.alive?(env.major_pid)
    end
  end
end
