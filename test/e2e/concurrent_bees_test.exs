defmodule GiTF.E2E.ConcurrentBeesTest do
  use GiTF.TestDriver.Scenario

  scenario "three concurrent ghosts all complete without store corruption" do
    {:ok, env, comb} = Harness.add_comb(env)

    {:ok, quest, [job1, job2, job3]} =
      Harness.create_quest(env,
        comb_id: comb.id,
        goal: "Concurrent ghosts test",
        jobs: [
          %{title: "Concurrent task 1"},
          %{title: "Concurrent task 2"},
          %{title: "Concurrent task 3"}
        ]
      )

    # Spawn all three ghosts at once with staggered delays
    {:ok, bee1} = Harness.spawn_mock_bee(env, job1.id, comb.id, delay_ms: 200)
    {:ok, bee2} = Harness.spawn_mock_bee(env, job2.id, comb.id, delay_ms: 400)
    {:ok, bee3} = Harness.spawn_mock_bee(env, job3.id, comb.id, delay_ms: 600)

    # Wait for all three to complete
    await({:job_done, job1.id}, timeout: 15_000)
    await({:job_done, job2.id}, timeout: 15_000)
    await({:job_done, job3.id}, timeout: 15_000)

    # All ghosts should be stopped
    await({:bee_stopped, bee1.id}, timeout: 5_000)
    await({:bee_stopped, bee2.id}, timeout: 5_000)
    await({:bee_stopped, bee3.id}, timeout: 5_000)

    # Verify no store corruption — all records should be retrievable
    {:ok, final_job1} = GiTF.Jobs.get(job1.id)
    {:ok, final_job2} = GiTF.Jobs.get(job2.id)
    {:ok, final_job3} = GiTF.Jobs.get(job3.id)

    assert final_job1.status == "done"
    assert final_job2.status == "done"
    assert final_job3.status == "done"

    # Wait for waggle messages — they arrive after the validation pipeline
    # in mark_success (may involve git diff + Claude validation)
    ghost_ids = [bee1.id, bee2.id, bee3.id]

    await(
      fn ->
        all_waggles = GiTF.Store.all(:waggles)
        bee_waggles = Enum.filter(all_waggles, &(&1.from in ghost_ids))
        length(bee_waggles) >= 3
      end,
      timeout: 15_000
    )

    # Quest should be completable
    GiTF.Quests.update_status!(quest.id)
    {:ok, final_quest} = GiTF.Quests.get(quest.id)
    assert final_quest.status == "completed"
  end

  scenario "concurrent ghosts produce separate cost records" do
    {:ok, env, comb} = Harness.add_comb(env)

    {:ok, _quest, [job1, job2]} =
      Harness.create_quest(env,
        comb_id: comb.id,
        goal: "Concurrent cost isolation test",
        jobs: [
          %{title: "Cost isolated task 1"},
          %{title: "Cost isolated task 2"}
        ]
      )

    events1 = GiTF.TestDriver.MockClaude.events_with_costs(100, 50, 0.001)
    events2 = GiTF.TestDriver.MockClaude.events_with_costs(300, 150, 0.005)

    {:ok, bee1} =
      Harness.spawn_mock_bee(env, job1.id, comb.id,
        delay_ms: 200,
        mock_opts: [events: events1]
      )

    {:ok, bee2} =
      Harness.spawn_mock_bee(env, job2.id, comb.id,
        delay_ms: 400,
        mock_opts: [events: events2]
      )

    await({:job_done, job1.id}, timeout: 15_000)
    await({:job_done, job2.id}, timeout: 15_000)

    # Brief pause for async cost recording to flush
    Process.sleep(100)

    # Each ghost should have its own cost records, not mixed
    costs1 = GiTF.Costs.for_bee(bee1.id)
    costs2 = GiTF.Costs.for_bee(bee2.id)

    assert length(costs1) > 0
    assert length(costs2) > 0

    total1 = GiTF.Costs.total(costs1)
    total2 = GiTF.Costs.total(costs2)

    # Costs should be different (different token counts)
    assert total1 != total2
  end
end
