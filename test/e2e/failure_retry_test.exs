defmodule Hive.E2E.FailureRetryTest do
  use Hive.TestDriver.Scenario

  scenario "failed bee sends job_failed waggle" do
    {:ok, env, comb} = Harness.add_comb(env)

    {:ok, _quest, [job1]} =
      Harness.create_quest(env,
        comb_id: comb.id,
        goal: "Failure test",
        jobs: [%{title: "Failing task"}]
      )

    # Spawn bee with exit_code: 1 (failure)
    {:ok, bee1} =
      Harness.spawn_mock_bee(env, job1.id, comb.id,
        exit_code: 1,
        delay_ms: 100,
        mock_opts: [events: Hive.TestDriver.MockClaude.failure_events()]
      )

    # Job should transition to failed
    await({:job_failed, job1.id}, timeout: 15_000)

    # Bee should be crashed
    await({:bee_stopped, bee1.id}, timeout: 5_000)

    # job_failed waggle should exist
    assert_waggle(subject: "job_failed")
  end

  scenario "Queen receives failure waggle and stays alive" do
    {:ok, env, comb} = Harness.add_comb(env)
    env = Harness.start_queen(env)

    {:ok, _quest, [job1]} =
      Harness.create_quest(env,
        comb_id: comb.id,
        goal: "Retry test",
        jobs: [%{title: "Retryable task"}]
      )

    # Spawn bee that will fail
    {:ok, bee1} =
      Harness.spawn_mock_bee(env, job1.id, comb.id,
        exit_code: 1,
        delay_ms: 100,
        mock_opts: [events: Hive.TestDriver.MockClaude.failure_events()]
      )

    # Wait for the bee to stop (it exited with code 1)
    await({:bee_stopped, bee1.id}, timeout: 15_000)

    # job_failed waggle should exist — the Worker sends it on failure
    # Note: we await the waggle rather than job status because Queen's
    # retry logic may reset the job back to "pending" before we check
    assert_waggle(subject: "job_failed")

    # Give Queen time to process waggle and attempt retry
    Process.sleep(1_000)

    # Queen should still be alive after processing retry logic
    # (retry spawn may fail without real Claude, but Queen shouldn't crash)
    assert Process.alive?(env.queen_pid)
  end

  scenario "Queen marks quest failed after retry exhaustion" do
    {:ok, env, comb} = Harness.add_comb(env)
    env = Harness.start_queen(env)

    {:ok, quest, [job1]} =
      Harness.create_quest(env,
        comb_id: comb.id,
        goal: "Exhaustion test",
        jobs: [%{title: "Exhausting task"}]
      )

    # Create a bee record and transition the job to failed state manually
    {:ok, bee} =
      Hive.Store.insert(:bees, %{name: "exhaust-bee", status: "working", job_id: job1.id})

    {:ok, _} = Hive.Jobs.assign(job1.id, bee.id)
    {:ok, _} = Hive.Jobs.start(job1.id)
    {:ok, _} = Hive.Jobs.fail(job1.id)

    # Set retry_count on job record to max so next failure triggers exhaustion
    job_record = Hive.Store.get(:jobs, job1.id)
    Hive.Store.put(:jobs, Map.put(job_record, :retry_count, 3))

    # Send failure waggle directly to Queen
    waggle = %{
      id: "wag-exhaust-#{:erlang.unique_integer([:positive])}",
      from: bee.id,
      to: "queen",
      subject: "job_failed",
      body: "Job failed after max retries",
      read: false
    }

    Harness.send_waggle_to_queen(waggle)

    # Quest should be marked as failed after exhaustion
    await({:quest_failed, quest.id}, timeout: 5_000)
  end
end
