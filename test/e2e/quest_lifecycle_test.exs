defmodule GiTF.E2E.QuestLifecycleTest do
  use GiTF.TestDriver.Scenario

  scenario "quest completes when all jobs finish" do
    {:ok, env, comb} = Harness.add_comb(env)

    {:ok, quest, [job1, job2]} =
      Harness.create_quest(env,
        comb_id: comb.id,
        goal: "Test quest lifecycle",
        jobs: [
          %{title: "First task"},
          %{title: "Second task"}
        ]
      )

    # Spawn mock ghosts for both jobs
    {:ok, bee1} = Harness.spawn_mock_bee(env, job1.id, comb.id, delay_ms: 200)
    {:ok, bee2} = Harness.spawn_mock_bee(env, job2.id, comb.id, delay_ms: 200)

    # Wait for both jobs to complete
    await({:job_done, job1.id}, timeout: 15_000)
    await({:job_done, job2.id}, timeout: 15_000)

    # Both ghosts should be stopped
    await({:bee_stopped, bee1.id}, timeout: 5_000)
    await({:bee_stopped, bee2.id}, timeout: 5_000)

    # Waggle messages arrive after the validation pipeline in mark_success
    # (may involve git diff + Claude validation, up to 60s). Wait generously.
    ghost_ids = [bee1.id, bee2.id]

    await(
      fn ->
        waggles = GiTF.Store.all(:waggles)
        Enum.any?(waggles, &(&1.from in ghost_ids))
      end,
      timeout: 15_000
    )

    # Both jobs done means quest should be completed
    GiTF.Quests.update_status!(quest.id)
    {:ok, final_quest} = GiTF.Quests.get(quest.id)
    assert final_quest.status == "completed"

    # Verify timeline captured telemetry events
    timeline = Recorder.timeline()
    assert length(timeline) > 0

    store_events = Recorder.events(type: :store)
    assert length(store_events) > 0
  end

  scenario "quest remains pending when only some jobs complete" do
    {:ok, env, comb} = Harness.add_comb(env)

    {:ok, quest, [job1, _job2]} =
      Harness.create_quest(env,
        comb_id: comb.id,
        goal: "Partial completion test",
        jobs: [
          %{title: "Completing task"},
          %{title: "Pending task"}
        ]
      )

    # Only spawn a ghost for job1
    {:ok, _bee1} = Harness.spawn_mock_bee(env, job1.id, comb.id, delay_ms: 100)

    await({:job_done, job1.id}, timeout: 15_000)

    # Update quest status
    GiTF.Quests.update_status!(quest.id)
    {:ok, updated_quest} = GiTF.Quests.get(quest.id)

    # job2 is still pending, so quest shouldn't be completed
    assert updated_quest.status != "completed"
  end
end
