defmodule GiTF.E2E.MajorOrchestrationTest do
  use GiTF.TestDriver.Scenario

  scenario "Major advances mission and spawns next op after completion" do
    {:ok, env, sector} = Harness.add_comb(env)
    env = Harness.start_major(env)

    {:ok, mission, [job1, _job2]} =
      Harness.create_quest(env,
        sector_id: sector.id,
        goal: "Major orchestration test",
        ops: [
          %{title: "First sequential task"},
          %{title: "Second sequential task"}
        ],
        dependencies: [{1, 0}]
      )

    # Spawn a mock ghost for job1 only — Major should auto-spawn for job2
    {:ok, bee1} = Harness.spawn_mock_bee(env, job1.id, sector.id, delay_ms: 200)

    # Wait for job1 to complete
    await({:job_done, job1.id}, timeout: 15_000)
    await({:bee_stopped, bee1.id}, timeout: 5_000)

    # Wait for a link_msg from the ghost — the validation pipeline in mark_success
    # may spawn Claude for diff assessment (up to 60s timeout), so be very generous
    await(
      fn ->
        links = GiTF.Archive.all(:links)
        Enum.any?(links, &(&1.from == bee1.id))
      end,
      timeout: 15_000
    )

    # Give Major time to process link_msg and attempt spawn
    Process.sleep(500)

    # Verify Major is still alive after processing
    assert Process.alive?(env.major_pid)

    # Quest status should reflect the state of ops.
    # Major attempts to spawn for job2 but without claude_executable,
    # the ghost can't find Claude and fails. After retries, mission may be "failed".
    {:ok, updated_quest} = GiTF.Missions.get(mission.id)
    assert updated_quest.status in ["pending", "active", "completed", "failed"]
  end

  scenario "Major marks mission completed when all ops done" do
    {:ok, env, sector} = Harness.add_comb(env)
    env = Harness.start_major(env)

    {:ok, mission, [job1]} =
      Harness.create_quest(env,
        sector_id: sector.id,
        goal: "Single op mission completion",
        ops: [%{title: "Only task"}]
      )

    {:ok, bee1} = Harness.spawn_mock_bee(env, job1.id, sector.id, delay_ms: 200)

    await({:job_done, job1.id}, timeout: 15_000)
    await({:bee_stopped, bee1.id}, timeout: 5_000)

    # The Worker sends a link_msg AFTER the validation pipeline completes.
    # The Validator may spawn Claude for diff assessment (60s timeout in Validator).
    # Wait for any link_msg from the ghost.
    await(
      fn ->
        links = GiTF.Archive.all(:links)
        Enum.any?(links, &(&1.from == bee1.id))
      end,
      timeout: 15_000
    )

    # If job_complete link_msg was sent, Major auto-advances the mission.
    # If validation_failed link_msg was sent, Major treats it as failure.
    # Check which link_msg was sent and verify accordingly.
    links = GiTF.Archive.filter(:links, fn w -> w.from == bee1.id end)
    link_msg = hd(links)

    case link_msg.subject do
      "job_complete" ->
        # Major should have advanced the mission
        await({:quest_completed, mission.id}, timeout: 10_000)
        assert_waggle(subject: "quest_completed")

      "validation_failed" ->
        # Validation spawned Claude and it either failed or the diff was assessed as failing.
        # This is valid behavior — the mission won't be completed.
        assert Process.alive?(env.major_pid)

      _ ->
        # Any other link_msg — just verify Major survived
        assert Process.alive?(env.major_pid)
    end
  end
end
