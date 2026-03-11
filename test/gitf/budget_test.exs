defmodule GiTF.BudgetTest do
  use ExUnit.Case, async: false

  alias GiTF.{Budget, Costs, Jobs}
  alias GiTF.Archive

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "gitf_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Archive.start_link(data_dir: tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, sector} =
      Archive.insert(:sectors, %{name: "budget-sector-#{:erlang.unique_integer([:positive])}"})

    {:ok, mission} =
      Archive.insert(:missions, %{
        name: "budget-mission-#{:erlang.unique_integer([:positive])}",
        status: "pending"
      })

    {:ok, ghost} =
      Archive.insert(:ghosts, %{
        name: "budget-ghost-#{:erlang.unique_integer([:positive])}",
        status: "starting"
      })

    {:ok, op} =
      Jobs.create(%{title: "budget op", mission_id: mission.id, sector_id: sector.id})

    {:ok, _} = Jobs.assign(op.id, ghost.id)

    %{sector: sector, mission: mission, ghost: ghost, op: op}
  end

  describe "spent_for/1" do
    test "returns 0 when no costs recorded", %{mission: mission} do
      assert Budget.spent_for(mission.id) == 0.0
    end

    test "sums costs for mission's ghosts", %{mission: mission, ghost: ghost} do
      {:ok, _} =
        Costs.record(ghost.id, %{
          input_tokens: 1000,
          output_tokens: 500,
          model: "claude-sonnet-4-20250514"
        })

      spent = Budget.spent_for(mission.id)
      assert spent > 0.0
    end
  end

  describe "check/1" do
    test "returns ok with remaining when under budget", %{mission: mission} do
      assert {:ok, remaining} = Budget.check(mission.id)
      assert remaining > 0
    end

    test "returns error when budget exceeded", %{mission: mission, ghost: ghost} do
      # Record a huge cost to exceed budget
      {:ok, _} = Costs.record(ghost.id, %{input_tokens: 0, output_tokens: 0, cost_usd: 999.0})

      assert {:error, :budget_exceeded, spent} = Budget.check(mission.id)
      assert spent >= 999.0
    end
  end

  describe "exceeded?/1" do
    test "returns false when under budget", %{mission: mission} do
      assert Budget.exceeded?(mission.id) == false
    end

    test "returns true when over budget", %{mission: mission, ghost: ghost} do
      {:ok, _} = Costs.record(ghost.id, %{input_tokens: 0, output_tokens: 0, cost_usd: 999.0})
      assert Budget.exceeded?(mission.id) == true
    end
  end

  describe "remaining/1" do
    test "returns full budget when nothing spent", %{mission: mission} do
      remaining = Budget.remaining(mission.id)
      assert remaining == Budget.budget_for(mission.id)
    end
  end
end
