defmodule GiTF.BudgetTest do
  use ExUnit.Case, async: false

  alias GiTF.{Budget, Costs, Jobs}
  alias GiTF.Store

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "gitf_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Store.start_link(data_dir: tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, comb} =
      Store.insert(:combs, %{name: "budget-comb-#{:erlang.unique_integer([:positive])}"})

    {:ok, quest} =
      Store.insert(:quests, %{
        name: "budget-quest-#{:erlang.unique_integer([:positive])}",
        status: "pending"
      })

    {:ok, ghost} =
      Store.insert(:ghosts, %{
        name: "budget-ghost-#{:erlang.unique_integer([:positive])}",
        status: "starting"
      })

    {:ok, job} =
      Jobs.create(%{title: "budget job", quest_id: quest.id, comb_id: comb.id})

    {:ok, _} = Jobs.assign(job.id, ghost.id)

    %{comb: comb, quest: quest, ghost: ghost, job: job}
  end

  describe "spent_for/1" do
    test "returns 0 when no costs recorded", %{quest: quest} do
      assert Budget.spent_for(quest.id) == 0.0
    end

    test "sums costs for quest's ghosts", %{quest: quest, ghost: ghost} do
      {:ok, _} =
        Costs.record(ghost.id, %{
          input_tokens: 1000,
          output_tokens: 500,
          model: "claude-sonnet-4-20250514"
        })

      spent = Budget.spent_for(quest.id)
      assert spent > 0.0
    end
  end

  describe "check/1" do
    test "returns ok with remaining when under budget", %{quest: quest} do
      assert {:ok, remaining} = Budget.check(quest.id)
      assert remaining > 0
    end

    test "returns error when budget exceeded", %{quest: quest, ghost: ghost} do
      # Record a huge cost to exceed budget
      {:ok, _} = Costs.record(ghost.id, %{input_tokens: 0, output_tokens: 0, cost_usd: 999.0})

      assert {:error, :budget_exceeded, spent} = Budget.check(quest.id)
      assert spent >= 999.0
    end
  end

  describe "exceeded?/1" do
    test "returns false when under budget", %{quest: quest} do
      assert Budget.exceeded?(quest.id) == false
    end

    test "returns true when over budget", %{quest: quest, ghost: ghost} do
      {:ok, _} = Costs.record(ghost.id, %{input_tokens: 0, output_tokens: 0, cost_usd: 999.0})
      assert Budget.exceeded?(quest.id) == true
    end
  end

  describe "remaining/1" do
    test "returns full budget when nothing spent", %{quest: quest} do
      remaining = Budget.remaining(quest.id)
      assert remaining == Budget.budget_for(quest.id)
    end
  end
end
