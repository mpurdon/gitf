defmodule Hive.DroneVerificationTest do
  use ExUnit.Case, async: false

  alias Hive.{Store, Drone}

  setup do
    # Start store for testing
    {:ok, _} = Store.start_link(data_dir: System.tmp_dir!())
    :ok
  end

  describe "verification patrol" do
    test "patrol includes verification checking" do
      # Start drone
      {:ok, pid} = Drone.start_link(poll_interval: 1000)

      # Trigger immediate patrol
      results = Drone.check_now()

      # Should return a list of results (may be empty)
      assert is_list(results)
      
      # Verification checking should not cause errors
      assert Process.alive?(pid)
    end

    test "drone starts with verify option" do
      # Start drone with verify enabled
      {:ok, pid} = Drone.start_link(poll_interval: 1000, verify: true)
      
      # Should start successfully
      assert Process.alive?(pid)
      
      # Should be able to run patrol
      results = Drone.check_now()
      assert is_list(results)
    end

    test "drone patrol handles verification gracefully" do
      # Create a job that needs verification
      {:ok, _job} = Store.insert(:jobs, %{
        title: "Test job",
        status: "done",
        verification_status: "pending"
      })

      # Start drone
      {:ok, pid} = Drone.start_link(poll_interval: 1000)
      
      # Should start successfully even with jobs needing verification
      assert Process.alive?(pid)
      
      # Patrol should complete without errors
      results = Drone.check_now()
      assert is_list(results)
    end
  end
end