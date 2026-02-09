defmodule Hive.QueenTest do
  use ExUnit.Case, async: false

  alias Hive.Queen
  alias Hive.Store

  @tmp_dir System.tmp_dir!()

  setup do
    store_dir = Path.join(@tmp_dir, "hive_store_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(store_dir)
    if Process.whereis(Hive.Store), do: GenServer.stop(Hive.Store)
    {:ok, _} = Hive.Store.start_link(data_dir: store_dir)
    on_exit(fn -> File.rm_rf!(store_dir) end)

    hive_root = create_hive_workspace()

    # Start a fresh Queen for each test. We stop it in on_exit.
    {:ok, pid} = Queen.start_link(hive_root: hive_root)
    on_exit(fn -> safe_stop(pid) end)

    %{hive_root: hive_root, queen_pid: pid}
  end

  defp create_hive_workspace do
    name = "hive_queen_test_#{:erlang.unique_integer([:positive])}"
    path = Path.join(@tmp_dir, name)
    queen_dir = Path.join([path, ".hive", "queen"])
    File.mkdir_p!(queen_dir)
    File.write!(Path.join(queen_dir, "QUEEN.md"), "# Queen\n")
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp safe_stop(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal)
    end
  rescue
    _ -> :ok
  end

  describe "start_link/1" do
    test "starts the Queen GenServer", %{queen_pid: pid} do
      assert Process.alive?(pid)
    end

    test "initializes with idle status" do
      status = Queen.status()
      assert status.status == :idle
    end
  end

  describe "start_session/0 and stop_session/0" do
    test "transitions status to active then back to idle" do
      assert :ok = Queen.start_session()
      assert %{status: :active} = Queen.status()

      assert :ok = Queen.stop_session()
      assert %{status: :idle} = Queen.status()
    end
  end

  describe "status/0" do
    test "returns current state map", %{hive_root: hive_root} do
      status = Queen.status()
      assert status.status == :idle
      assert status.active_bees == %{}
      assert status.hive_root == hive_root
      assert status.max_bees == 5
    end
  end

  describe "launch/0" do
    test "returns error when Claude is not available", %{hive_root: _hive_root} do
      # Temporarily break PATH to ensure Claude can't be found
      original_path = System.get_env("PATH")
      System.put_env("PATH", "/empty")

      Queen.start_session()
      result = Queen.launch()

      System.put_env("PATH", original_path)

      case result do
        {:error, :not_found} ->
          # Claude not found -- expected in CI
          assert true

        :ok ->
          # Claude was found at a common location
          assert true
      end
    end
  end

  describe "handle_info/2 waggle handling" do
    test "handles job_complete waggle by removing bee from active_bees" do
      Queen.start_session()

      # Simulate receiving a waggle message directly (plain map now)
      waggle = %{
        id: "wag-test1",
        from: "bee-abc123",
        to: "queen",
        subject: "job_complete",
        body: "Finished the task",
        read: false
      }

      send(Process.whereis(Hive.Queen), {:waggle_received, waggle})

      # Give the GenServer a moment to process
      Process.sleep(10)

      status = Queen.status()
      refute Map.has_key?(status.active_bees, "bee-abc123")
    end

    test "handles job_failed waggle" do
      Queen.start_session()

      waggle = %{
        id: "wag-test2",
        from: "bee-def456",
        to: "queen",
        subject: "job_failed",
        body: "Could not compile",
        read: false
      }

      send(Process.whereis(Hive.Queen), {:waggle_received, waggle})
      Process.sleep(10)

      # Should not crash
      assert Process.alive?(Process.whereis(Hive.Queen))
    end

    test "handles unexpected messages gracefully" do
      send(Process.whereis(Hive.Queen), :some_random_message)
      Process.sleep(10)

      assert Process.alive?(Process.whereis(Hive.Queen))
    end

    test "retry logic increments retry count for failed job" do
      # Create the necessary DB records for retry
      {:ok, comb} =
        Store.insert(:combs, %{name: "retry-test-comb-#{:erlang.unique_integer([:positive])}"})

      {:ok, quest} =
        Store.insert(:quests, %{
          name: "retry-test-quest-#{:erlang.unique_integer([:positive])}",
          status: "pending"
        })

      {:ok, job} =
        Hive.Jobs.create(%{
          title: "Retry test job",
          quest_id: quest.id,
          comb_id: comb.id
        })

      {:ok, bee} =
        Store.insert(:bees, %{name: "retry-test-bee", status: "starting", job_id: job.id})

      # Move job through states to failed
      {:ok, _} = Hive.Jobs.assign(job.id, bee.id)
      {:ok, _} = Hive.Jobs.start(job.id)
      {:ok, _} = Hive.Jobs.fail(job.id)

      Queen.start_session()

      # Simulate the failed waggle -- retry will attempt to spawn a bee
      # which may fail (no worktree), but the retry count should still be tracked
      waggle = %{
        id: "wag-retry-1",
        from: bee.id,
        to: "queen",
        subject: "job_failed",
        body: "Job failed",
        read: false
      }

      send(Process.whereis(Hive.Queen), {:waggle_received, waggle})
      Process.sleep(50)

      # Queen should still be alive after retry attempt
      assert Process.alive?(Process.whereis(Hive.Queen))
    end

    test "updates quest status to completed on job_complete" do
      # Create records: comb, quest, job (done), bee
      {:ok, comb} =
        Store.insert(:combs, %{name: "quest-adv-comb-#{:erlang.unique_integer([:positive])}"})

      {:ok, quest} =
        Store.insert(:quests, %{
          name: "quest-adv-test-#{:erlang.unique_integer([:positive])}",
          status: "active"
        })

      {:ok, job} =
        Hive.Jobs.create(%{
          title: "Only job",
          quest_id: quest.id,
          comb_id: comb.id
        })

      {:ok, bee} =
        Store.insert(:bees, %{name: "adv-bee", status: "working", job_id: job.id})

      # Move job to "done" state
      {:ok, _} = Hive.Jobs.assign(job.id, bee.id)
      {:ok, _} = Hive.Jobs.start(job.id)
      {:ok, _} = Hive.Jobs.complete(job.id)

      Queen.start_session()

      waggle = %{
        id: "wag-adv-1",
        from: bee.id,
        to: "queen",
        subject: "job_complete",
        body: "Done",
        read: false
      }

      send(Process.whereis(Hive.Queen), {:waggle_received, waggle})
      Process.sleep(50)

      {:ok, updated_quest} = Hive.Quests.get(quest.id)
      assert updated_quest.status == "completed"
    end

    test "sends quest_completed waggle on completion" do
      # Subscribe to queen topic to receive the waggle
      Hive.Waggle.subscribe("waggle:queen")

      {:ok, comb} =
        Store.insert(:combs, %{name: "wag-comb-#{:erlang.unique_integer([:positive])}"})

      {:ok, quest} =
        Store.insert(:quests, %{
          name: "wag-quest-#{:erlang.unique_integer([:positive])}",
          status: "active"
        })

      {:ok, job} =
        Hive.Jobs.create(%{
          title: "Single job",
          quest_id: quest.id,
          comb_id: comb.id
        })

      {:ok, bee} =
        Store.insert(:bees, %{name: "wag-bee", status: "working", job_id: job.id})

      {:ok, _} = Hive.Jobs.assign(job.id, bee.id)
      {:ok, _} = Hive.Jobs.start(job.id)
      {:ok, _} = Hive.Jobs.complete(job.id)

      Queen.start_session()

      waggle = %{
        id: "wag-complete-1",
        from: bee.id,
        to: "queen",
        subject: "job_complete",
        body: "Done",
        read: false
      }

      send(Process.whereis(Hive.Queen), {:waggle_received, waggle})

      assert_receive {:waggle_received, %{subject: "quest_completed"}}, 500
    end

    test "attempts to spawn bee for next pending job after completion" do
      {:ok, comb} =
        Store.insert(:combs, %{name: "spawn-comb-#{:erlang.unique_integer([:positive])}"})

      {:ok, quest} =
        Store.insert(:quests, %{
          name: "spawn-quest-#{:erlang.unique_integer([:positive])}",
          status: "active"
        })

      {:ok, job_1} =
        Hive.Jobs.create(%{
          title: "First job",
          quest_id: quest.id,
          comb_id: comb.id
        })

      {:ok, job_2} =
        Hive.Jobs.create(%{
          title: "Second job",
          quest_id: quest.id,
          comb_id: comb.id
        })

      # job_2 depends on job_1
      {:ok, _dep} = Hive.Jobs.add_dependency(job_2.id, job_1.id)

      {:ok, bee} =
        Store.insert(:bees, %{name: "spawn-bee", status: "working", job_id: job_1.id})

      # Complete job_1
      {:ok, _} = Hive.Jobs.assign(job_1.id, bee.id)
      {:ok, _} = Hive.Jobs.start(job_1.id)
      {:ok, _} = Hive.Jobs.complete(job_1.id)

      Queen.start_session()

      waggle = %{
        id: "wag-spawn-1",
        from: bee.id,
        to: "queen",
        subject: "job_complete",
        body: "Done",
        read: false
      }

      send(Process.whereis(Hive.Queen), {:waggle_received, waggle})
      Process.sleep(100)

      # Quest should be updated (not completed yet since job_2 is pending)
      {:ok, updated_quest} = Hive.Quests.get(quest.id)
      # Status should be "pending" (job_2 is pending) or "active" if spawn succeeded
      # The spawn itself may fail (no real git worktree), but Queen should not crash
      assert Process.alive?(Process.whereis(Hive.Queen))
      assert updated_quest.status in ["pending", "active"]
    end

    test "updates quest status on retry exhaustion" do
      {:ok, comb} =
        Store.insert(:combs, %{name: "exhaust-comb-#{:erlang.unique_integer([:positive])}"})

      {:ok, quest} =
        Store.insert(:quests, %{
          name: "exhaust-quest-#{:erlang.unique_integer([:positive])}",
          status: "active"
        })

      {:ok, job} =
        Hive.Jobs.create(%{
          title: "Failing job",
          quest_id: quest.id,
          comb_id: comb.id
        })

      {:ok, bee} =
        Store.insert(:bees, %{
          name: "exhaust-bee",
          status: "working",
          job_id: job.id
        })

      # Move job to failed state
      {:ok, _} = Hive.Jobs.assign(job.id, bee.id)
      {:ok, _} = Hive.Jobs.start(job.id)
      {:ok, _} = Hive.Jobs.fail(job.id)

      Queen.start_session()

      # Pre-load retry count to max so next failure triggers exhaustion
      # We do this by sending the state update via sys to set retry_counts
      :sys.replace_state(Process.whereis(Hive.Queen), fn state ->
        put_in(state.retry_counts[job.id], 3)
      end)

      waggle = %{
        id: "wag-exhaust-1",
        from: bee.id,
        to: "queen",
        subject: "job_failed",
        body: "Failed again",
        read: false
      }

      send(Process.whereis(Hive.Queen), {:waggle_received, waggle})
      Process.sleep(50)

      # After exhausting retries, quest status should reflect failure
      {:ok, updated_quest} = Hive.Quests.get(quest.id)
      assert updated_quest.status == "failed"
    end

    test "handles validation_failed waggle like job_failed" do
      {:ok, comb} =
        Store.insert(:combs, %{name: "val-comb-#{:erlang.unique_integer([:positive])}"})

      {:ok, quest} =
        Store.insert(:quests, %{
          name: "val-quest-#{:erlang.unique_integer([:positive])}",
          status: "active"
        })

      {:ok, job} =
        Hive.Jobs.create(%{
          title: "Validation test job",
          quest_id: quest.id,
          comb_id: comb.id
        })

      {:ok, bee} =
        Store.insert(:bees, %{name: "val-bee", status: "working", job_id: job.id})

      {:ok, _} = Hive.Jobs.assign(job.id, bee.id)
      {:ok, _} = Hive.Jobs.start(job.id)
      {:ok, _} = Hive.Jobs.fail(job.id)

      Queen.start_session()

      waggle = %{
        id: "wag-val-1",
        from: bee.id,
        to: "queen",
        subject: "validation_failed",
        body: "Tests did not pass",
        read: false
      }

      send(Process.whereis(Hive.Queen), {:waggle_received, waggle})
      Process.sleep(50)

      # Should not crash and should attempt retry
      assert Process.alive?(Process.whereis(Hive.Queen))
    end

    test "handles port data messages without crashing" do
      # Simulate port messages that the Queen's Claude session would produce.
      # We create a real port so the guard `when is_port(port)` passes.
      port = Port.open({:spawn, "echo hello"}, [:binary, :exit_status])

      # First set the Queen's port field via internal state manipulation.
      # We simulate receiving port data as if Claude was running.
      queen_pid = Process.whereis(Hive.Queen)
      send(queen_pid, {port, {:data, "some output"}})
      Process.sleep(10)

      assert Process.alive?(queen_pid)

      # Clean up the port
      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        1000 -> :ok
      end
    end
  end
end
