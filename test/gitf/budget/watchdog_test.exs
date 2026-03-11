defmodule GiTF.Budget.WatchdogTest do
  use ExUnit.Case, async: false

  alias GiTF.Store

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    # Use a fresh store to avoid stale data from other tests
    tmp_dir = Path.join(System.tmp_dir!(), "gitf_budget_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = Store.start_link(data_dir: tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    # Terminate Budget.Watchdog from supervisor to prevent auto-restart conflicts
    try do
      Supervisor.terminate_child(GiTF.Supervisor, GiTF.Budget.Watchdog)
      Supervisor.delete_child(GiTF.Supervisor, GiTF.Budget.Watchdog)
    catch
      :exit, _ -> :ok
    end
    GiTF.Test.StoreHelper.safe_stop(GiTF.Budget.Watchdog)
    Process.sleep(10)
    {:ok, _} = GiTF.Budget.Watchdog.start_link([])

    # Use unique IDs to avoid collisions
    suffix = :erlang.unique_integer([:positive])
    quest_id = "q-test-budget-#{suffix}"
    ghost_id = "b-test-budget-#{suffix}"
    job_id = "j-test-budget-#{suffix}"

    # Create test data
    Store.insert(:quests, %{id: quest_id, status: "active", goal: "Test Budget"})
    Store.insert(:jobs, %{id: job_id, quest_id: quest_id, ghost_id: ghost_id, status: "assigned"})
    Store.insert(:ghosts, %{id: ghost_id, job_id: job_id, status: "working", pid: "dummy"})

    {:ok, %{quest_id: quest_id, ghost_id: ghost_id}}
  end

  test "watchdog kills ghost when budget exceeded", %{quest_id: quest_id, ghost_id: ghost_id} do
    # 1. Artificially inflate the cost (default budget is 10.0)
    GiTF.Costs.record(ghost_id, %{cost_usd: 100.0})

    # Verify budget is actually exceeded
    assert {:error, :budget_exceeded, _} = GiTF.Budget.check(quest_id)

    # 2. Trigger watchdog check manually
    watchdog = Process.whereis(GiTF.Budget.Watchdog)
    assert watchdog != nil, "Budget.Watchdog is not running"
    send(watchdog, :check_budgets)

    # 3. Flush the message queue by doing a sync call
    :sys.get_state(watchdog)

    # 4. Quest should be marked as failed_budget or paused_budget
    # (paused_budget when no active ghosts are running worker processes)
    quest = Store.get(:quests, quest_id)
    assert quest.status in ["failed_budget", "paused_budget"]
  end
end
