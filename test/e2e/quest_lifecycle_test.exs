defmodule GiTF.E2E.QuestLifecycleTest do
  use GiTF.TestDriver.Scenario

  scenario "mission completes when all ops finish" do
    {:ok, env, sector} = Harness.add_comb(env)

    {:ok, mission, [job1, job2]} =
      Harness.create_quest(env,
        sector_id: sector.id,
        goal: "Test mission lifecycle",
        ops: [
          %{title: "First task"},
          %{title: "Second task"}
        ]
      )

    # Spawn mock ghosts for both ops
    {:ok, bee1} = Harness.spawn_mock_bee(env, job1.id, sector.id, delay_ms: 200)
    {:ok, bee2} = Harness.spawn_mock_bee(env, job2.id, sector.id, delay_ms: 200)

    # Wait for both ops to complete
    await({:job_done, job1.id}, timeout: 15_000)
    await({:job_done, job2.id}, timeout: 15_000)

    # Both ghosts should be stopped
    await({:bee_stopped, bee1.id}, timeout: 5_000)
    await({:bee_stopped, bee2.id}, timeout: 5_000)

    # Link messages arrive after the validation pipeline in mark_success
    # (may involve git diff + Claude validation, up to 60s). Wait generously.
    ghost_ids = [bee1.id, bee2.id]

    await(
      fn ->
        links = GiTF.Archive.all(:links)
        Enum.any?(links, &(&1.from in ghost_ids))
      end,
      timeout: 15_000
    )

    # Both ops done means mission should be completed
    GiTF.Missions.update_status!(mission.id)
    {:ok, final_quest} = GiTF.Missions.get(mission.id)
    assert final_quest.status == "completed"

    # Verify timeline captured telemetry events
    timeline = Recorder.timeline()
    assert length(timeline) > 0

    store_events = Recorder.events(type: :store)
    assert length(store_events) > 0
  end

  scenario "mission remains pending when only some ops complete" do
    {:ok, env, sector} = Harness.add_comb(env)

    {:ok, mission, [job1, _job2]} =
      Harness.create_quest(env,
        sector_id: sector.id,
        goal: "Partial completion test",
        ops: [
          %{title: "Completing task"},
          %{title: "Pending task"}
        ]
      )

    # Only spawn a ghost for job1
    {:ok, _bee1} = Harness.spawn_mock_bee(env, job1.id, sector.id, delay_ms: 100)

    await({:job_done, job1.id}, timeout: 15_000)

    # Update mission status
    GiTF.Missions.update_status!(mission.id)
    {:ok, updated_quest} = GiTF.Missions.get(mission.id)

    # job2 is still pending, so mission shouldn't be completed
    assert updated_quest.status != "completed"
  end
end
