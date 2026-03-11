defmodule GiTF.E2E.FailureRetryTest do
  use GiTF.TestDriver.Scenario

  scenario "failed ghost sends job_failed link_msg" do
    {:ok, env, sector} = Harness.add_comb(env)

    {:ok, _quest, [job1]} =
      Harness.create_quest(env,
        sector_id: sector.id,
        goal: "Failure test",
        ops: [%{title: "Failing task"}]
      )

    # Spawn ghost with exit_code: 1 (failure)
    {:ok, bee1} =
      Harness.spawn_mock_bee(env, job1.id, sector.id,
        exit_code: 1,
        delay_ms: 100,
        mock_opts: [events: GiTF.TestDriver.MockClaude.failure_events()]
      )

    # Job should transition to failed
    await({:job_failed, job1.id}, timeout: 15_000)

    # Bee should be crashed
    await({:bee_stopped, bee1.id}, timeout: 5_000)

    # job_failed link_msg should exist
    assert_waggle(subject: "job_failed")
  end

  scenario "Major receives failure link_msg and stays alive" do
    {:ok, env, sector} = Harness.add_comb(env)
    env = Harness.start_major(env)

    {:ok, _quest, [job1]} =
      Harness.create_quest(env,
        sector_id: sector.id,
        goal: "Retry test",
        ops: [%{title: "Retryable task"}]
      )

    # Spawn ghost that will fail
    {:ok, bee1} =
      Harness.spawn_mock_bee(env, job1.id, sector.id,
        exit_code: 1,
        delay_ms: 100,
        mock_opts: [events: GiTF.TestDriver.MockClaude.failure_events()]
      )

    # Wait for the ghost to stop (it exited with code 1)
    await({:bee_stopped, bee1.id}, timeout: 15_000)

    # job_failed link_msg should exist — the Worker sends it on failure
    # Note: we await the link_msg rather than op status because Major's
    # retry logic may reset the op back to "pending" before we check
    assert_waggle(subject: "job_failed")

    # Give Major time to process link_msg and attempt retry
    Process.sleep(1_000)

    # Major should still be alive after processing retry logic
    # (retry spawn may fail without real Claude, but Major shouldn't crash)
    assert Process.alive?(env.major_pid)
  end

  scenario "Major marks mission failed after retry exhaustion" do
    {:ok, env, sector} = Harness.add_comb(env)
    env = Harness.start_major(env)

    {:ok, mission, [job1]} =
      Harness.create_quest(env,
        sector_id: sector.id,
        goal: "Exhaustion test",
        ops: [%{title: "Exhausting task"}]
      )

    # Create a ghost record and transition the op to failed state manually
    {:ok, ghost} =
      GiTF.Archive.insert(:ghosts, %{name: "exhaust-ghost", status: "working", op_id: job1.id})

    {:ok, _} = GiTF.Ops.assign(job1.id, ghost.id)
    {:ok, _} = GiTF.Ops.start(job1.id)
    {:ok, _} = GiTF.Ops.fail(job1.id)

    # Set retry_count on op record to max so next failure triggers exhaustion
    job_record = GiTF.Archive.get(:ops, job1.id)
    GiTF.Archive.put(:ops, Map.put(job_record, :retry_count, 3))

    # Send failure link_msg directly to Major
    link_msg = %{
      id: "wag-exhaust-#{:erlang.unique_integer([:positive])}",
      from: ghost.id,
      to: "major",
      subject: "job_failed",
      body: "Job failed after max retries",
      read: false
    }

    Harness.send_waggle_to_major(link_msg)

    # Quest should be marked as failed after exhaustion
    await({:quest_failed, mission.id}, timeout: 5_000)
  end
end
