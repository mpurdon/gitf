defmodule GiTF.E2E.FailureRetryTest do
  use GiTF.TestDriver.Scenario

  scenario "failed ghost sends job_failed waggle" do
    {:ok, env, comb} = Harness.add_comb(env)

    {:ok, _quest, [job1]} =
      Harness.create_quest(env,
        comb_id: comb.id,
        goal: "Failure test",
        jobs: [%{title: "Failing task"}]
      )

    # Spawn ghost with exit_code: 1 (failure)
    {:ok, bee1} =
      Harness.spawn_mock_bee(env, job1.id, comb.id,
        exit_code: 1,
        delay_ms: 100,
        mock_opts: [events: GiTF.TestDriver.MockClaude.failure_events()]
      )

    # Job should transition to failed
    await({:job_failed, job1.id}, timeout: 15_000)

    # Bee should be crashed
    await({:bee_stopped, bee1.id}, timeout: 5_000)

    # job_failed waggle should exist
    assert_waggle(subject: "job_failed")
  end

  scenario "Major receives failure waggle and stays alive" do
    {:ok, env, comb} = Harness.add_comb(env)
    env = Harness.start_major(env)

    {:ok, _quest, [job1]} =
      Harness.create_quest(env,
        comb_id: comb.id,
        goal: "Retry test",
        jobs: [%{title: "Retryable task"}]
      )

    # Spawn ghost that will fail
    {:ok, bee1} =
      Harness.spawn_mock_bee(env, job1.id, comb.id,
        exit_code: 1,
        delay_ms: 100,
        mock_opts: [events: GiTF.TestDriver.MockClaude.failure_events()]
      )

    # Wait for the ghost to stop (it exited with code 1)
    await({:bee_stopped, bee1.id}, timeout: 15_000)

    # job_failed waggle should exist — the Worker sends it on failure
    # Note: we await the waggle rather than job status because Major's
    # retry logic may reset the job back to "pending" before we check
    assert_waggle(subject: "job_failed")

    # Give Major time to process waggle and attempt retry
    Process.sleep(1_000)

    # Major should still be alive after processing retry logic
    # (retry spawn may fail without real Claude, but Major shouldn't crash)
    assert Process.alive?(env.major_pid)
  end

  scenario "Major marks quest failed after retry exhaustion" do
    {:ok, env, comb} = Harness.add_comb(env)
    env = Harness.start_major(env)

    {:ok, quest, [job1]} =
      Harness.create_quest(env,
        comb_id: comb.id,
        goal: "Exhaustion test",
        jobs: [%{title: "Exhausting task"}]
      )

    # Create a ghost record and transition the job to failed state manually
    {:ok, ghost} =
      GiTF.Store.insert(:ghosts, %{name: "exhaust-ghost", status: "working", job_id: job1.id})

    {:ok, _} = GiTF.Jobs.assign(job1.id, ghost.id)
    {:ok, _} = GiTF.Jobs.start(job1.id)
    {:ok, _} = GiTF.Jobs.fail(job1.id)

    # Set retry_count on job record to max so next failure triggers exhaustion
    job_record = GiTF.Store.get(:jobs, job1.id)
    GiTF.Store.put(:jobs, Map.put(job_record, :retry_count, 3))

    # Send failure waggle directly to Major
    waggle = %{
      id: "wag-exhaust-#{:erlang.unique_integer([:positive])}",
      from: ghost.id,
      to: "major",
      subject: "job_failed",
      body: "Job failed after max retries",
      read: false
    }

    Harness.send_waggle_to_major(waggle)

    # Quest should be marked as failed after exhaustion
    await({:quest_failed, quest.id}, timeout: 5_000)
  end
end
