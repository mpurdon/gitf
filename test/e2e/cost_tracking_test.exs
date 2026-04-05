defmodule GiTF.E2E.CostTrackingTest do
  use GiTF.TestDriver.Scenario

  scenario "cost data is recorded from mock Claude output" do
    {:ok, env, sector} = Harness.add_sector(env)

    {:ok, _quest, [job1]} =
      Harness.create_quest(env,
        sector_id: sector.id,
        goal: "Cost tracking test",
        ops: [%{title: "Cost-tracked task"}]
      )

    input_tokens = 500
    output_tokens = 200
    cost_usd = 0.0045

    events =
      GiTF.TestDriver.MockClaude.events_with_costs(input_tokens, output_tokens, cost_usd,
        model: "claude-sonnet-4-20250514"
      )

    {:ok, bee1} =
      Harness.spawn_mock_bee(env, job1.id, sector.id,
        delay_ms: 100,
        mock_opts: [events: events]
      )

    # Wait for completion
    await({:job_done, job1.id}, timeout: 15_000)
    await({:bee_stopped, bee1.id}, timeout: 5_000)

    # Verify costs were recorded
    bee_costs = GiTF.Costs.for_bee(bee1.id)
    assert length(bee_costs) > 0

    cost = hd(bee_costs)
    assert cost.input_tokens == input_tokens
    assert cost.output_tokens == output_tokens
    assert cost.cost_usd == cost_usd
    assert cost.model == "claude-sonnet-4-20250514"
  end

  scenario "cost summary aggregates across ghosts" do
    {:ok, env, sector} = Harness.add_sector(env)

    {:ok, _quest, [job1, job2]} =
      Harness.create_quest(env,
        sector_id: sector.id,
        goal: "Multi-ghost cost test",
        ops: [
          %{title: "Cost task 1"},
          %{title: "Cost task 2"}
        ]
      )

    events1 =
      GiTF.TestDriver.MockClaude.events_with_costs(100, 50, 0.001)

    events2 =
      GiTF.TestDriver.MockClaude.events_with_costs(200, 100, 0.002)

    {:ok, bee1} =
      Harness.spawn_mock_bee(env, job1.id, sector.id,
        delay_ms: 100,
        mock_opts: [events: events1]
      )

    {:ok, bee2} =
      Harness.spawn_mock_bee(env, job2.id, sector.id,
        delay_ms: 100,
        mock_opts: [events: events2]
      )

    await({:job_done, job1.id}, timeout: 15_000)
    await({:job_done, job2.id}, timeout: 15_000)
    await({:bee_stopped, bee1.id}, timeout: 5_000)
    await({:bee_stopped, bee2.id}, timeout: 5_000)

    # Check aggregate summary
    summary = GiTF.Costs.summary()
    assert summary.total_cost > 0
    assert summary.total_input_tokens >= 300
    assert summary.total_output_tokens >= 150

    # by_bee should have entries for both ghosts
    assert Map.has_key?(summary.by_bee, bee1.id)
    assert Map.has_key?(summary.by_bee, bee2.id)
  end
end
