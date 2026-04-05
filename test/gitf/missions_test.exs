defmodule GiTF.MissionsTest do
  use GiTF.StoreCase

  alias GiTF.Missions
  alias GiTF.Archive

  setup do
    {:ok, sector} =
      Archive.insert(:sectors, %{
        name: "missions-test-sector-#{:erlang.unique_integer([:positive])}"
      })

    %{sector: sector}
  end

  describe "create/1" do
    test "creates a mission with a goal and auto-generates name" do
      assert {:ok, mission} = Missions.create(%{goal: "Refactor the auth module"})
      assert mission.goal == "Refactor the auth module"
      assert mission.name == "refactor-the-auth-module"
      assert mission.status == "pending"
      assert String.starts_with?(mission.id, "msn-")
    end

    test "accepts optional sector_id", %{sector: sector} do
      assert {:ok, mission} = Missions.create(%{goal: "Build feature", sector_id: sector.id})
      assert mission.sector_id == sector.id
    end

    test "accepts explicit name override" do
      assert {:ok, mission} = Missions.create(%{goal: "Do the thing", name: "custom-name"})
      assert mission.name == "custom-name"
      assert mission.goal == "Do the thing"
    end

    test "requires goal" do
      assert {:error, {:missing_fields, [:goal]}} = Missions.create(%{})
    end
  end

  describe "get/1" do
    test "retrieves a mission by ID and preloads ops" do
      {:ok, mission} = Missions.create(%{goal: "Find mission"})

      assert {:ok, found} = Missions.get(mission.id)
      assert found.id == mission.id
      assert found.ops == []
    end

    test "returns error for unknown ID" do
      assert {:error, :not_found} = Missions.get("msn-000000")
    end
  end

  describe "list/1" do
    test "returns all missions" do
      {:ok, _} = Missions.create(%{goal: "Quest 1"})
      {:ok, _} = Missions.create(%{goal: "Quest 2"})

      missions = Missions.list()
      assert length(missions) >= 2
    end

    test "filters by status" do
      {:ok, _} = Missions.create(%{goal: "Pending mission"})
      {:ok, q} = Missions.create(%{goal: "Active mission"})

      Archive.put(:missions, %{q | status: "active"})

      pending = Missions.list(status: "pending")
      assert Enum.all?(pending, &(&1.status == "pending"))

      active = Missions.list(status: "active")
      assert length(active) >= 1
    end
  end

  describe "compute_status/1" do
    test "returns pending for empty op list" do
      assert Missions.compute_status([]) == "pending"
    end

    test "returns active when all ops are pending" do
      assert Missions.compute_status(["pending", "pending"]) == "active"
    end

    test "returns completed when all ops are done" do
      assert Missions.compute_status(["done", "done", "done"]) == "completed"
    end

    test "returns active when any op has failed but others are pending" do
      assert Missions.compute_status(["done", "failed", "pending"]) == "active"
    end

    test "returns active when any op is running" do
      assert Missions.compute_status(["done", "running", "pending"]) == "active"
    end

    test "returns active when any op is assigned" do
      assert Missions.compute_status(["pending", "assigned"]) == "active"
    end

    test "returns active for mixed pending and blocked" do
      assert Missions.compute_status(["pending", "blocked"]) == "active"
    end

    test "returns failed when ops are only done or failed (no pending/running)" do
      assert Missions.compute_status(["done", "failed"]) == "failed"
    end

    test "returns active when running despite failed op" do
      assert Missions.compute_status(["running", "failed"]) == "active"
    end
  end

  describe "update_status!/1" do
    test "recomputes status from op statuses", %{sector: sector} do
      {:ok, mission} = Missions.create(%{goal: "Update status mission"})

      {:ok, _} =
        GiTF.Ops.create(%{
          title: "Done op",
          mission_id: mission.id,
          sector_id: sector.id,
          status: "done"
        })

      {:ok, _} =
        GiTF.Ops.create(%{
          title: "Running op",
          mission_id: mission.id,
          sector_id: sector.id,
          status: "running"
        })

      assert {:ok, updated} = Missions.update_status!(mission.id)
      assert updated.status == "active"
    end

    test "sets completed when all ops done", %{sector: sector} do
      {:ok, mission} = Missions.create(%{goal: "Complete mission"})

      {:ok, _} =
        GiTF.Ops.create(%{
          title: "Job 1",
          mission_id: mission.id,
          sector_id: sector.id,
          status: "done"
        })

      {:ok, _} =
        GiTF.Ops.create(%{
          title: "Job 2",
          mission_id: mission.id,
          sector_id: sector.id,
          status: "done"
        })

      assert {:ok, updated} = Missions.update_status!(mission.id)
      assert updated.status == "completed"
    end
  end

  describe "close/1" do
    test "sets mission status to closed", %{sector: sector} do
      {:ok, mission} = Missions.create(%{goal: "Close me", sector_id: sector.id})

      assert {:ok, closed} = Missions.close(mission.id)
      assert closed.status == "closed"

      # Verify persisted
      assert {:ok, fetched} = Missions.get(mission.id)
      assert fetched.status == "closed"
    end

    test "closes mission with ops that have no ghosts", %{sector: sector} do
      {:ok, mission} = Missions.create(%{goal: "Quest with unassigned ops"})

      {:ok, _job} =
        GiTF.Ops.create(%{title: "Unassigned op", mission_id: mission.id, sector_id: sector.id})

      assert {:ok, closed} = Missions.close(mission.id)
      assert closed.status == "closed"
    end

    test "attempts to remove active shells for assigned ghosts", %{sector: sector} do
      {:ok, mission} = Missions.create(%{goal: "Quest with ghosts"})

      {:ok, op} =
        GiTF.Ops.create(%{
          title: "Job with ghost",
          mission_id: mission.id,
          sector_id: sector.id,
          status: "done"
        })

      {:ok, ghost} =
        Archive.insert(:ghosts, %{name: "test-ghost", op_id: op.id, status: "stopped"})

      GiTF.Ops.assign(op.id, ghost.id)

      {:ok, _cell} =
        Archive.insert(:shells, %{
          ghost_id: ghost.id,
          sector_id: sector.id,
          worktree_path: "/tmp/fake-worktree-#{ghost.id}",
          branch: "ghost/#{ghost.id}",
          status: "active"
        })

      # close/1 will attempt Shell.remove which may fail on fake worktree,
      # but mission status should still be set to "closed"
      assert {:ok, closed} = Missions.close(mission.id)
      assert closed.status == "closed"
    end

    test "returns error for unknown mission" do
      assert {:error, :not_found} = Missions.close("msn-nonexistent")
    end
  end

  describe "set_planning/1" do
    test "transitions pending mission to planning" do
      {:ok, mission} = Missions.create(%{goal: "Plan this"})
      assert mission.status == "pending"

      assert {:ok, updated} = Missions.set_planning(mission.id)
      assert updated.status == "planning"
    end

    test "rejects transition from non-pending status" do
      {:ok, mission} = Missions.create(%{goal: "Already active"})
      Archive.put(:missions, %{mission | status: "active"})

      assert {:error, :invalid_transition} = Missions.set_planning(mission.id)
    end

    test "rejects transition from planning (idempotent guard)" do
      {:ok, mission} = Missions.create(%{goal: "Already planning"})
      {:ok, _} = Missions.set_planning(mission.id)

      assert {:error, :invalid_transition} = Missions.set_planning(mission.id)
    end

    test "returns not_found for unknown mission" do
      assert {:error, :not_found} = Missions.set_planning("msn-nonexistent")
    end
  end

  describe "update_status!/1 with planning" do
    test "preserves planning status when mission has no ops" do
      {:ok, mission} = Missions.create(%{goal: "Planning mission"})
      {:ok, _} = Missions.set_planning(mission.id)

      assert {:ok, updated} = Missions.update_status!(mission.id)
      assert updated.status == "planning"
    end

    test "computes status normally once planning mission has ops", %{sector: sector} do
      {:ok, mission} = Missions.create(%{goal: "Planning with ops"})
      {:ok, _} = Missions.set_planning(mission.id)

      {:ok, _} =
        GiTF.Ops.create(%{
          title: "First op",
          mission_id: mission.id,
          sector_id: sector.id,
          status: "running"
        })

      assert {:ok, updated} = Missions.update_status!(mission.id)
      assert updated.status == "active"
    end
  end

  describe "add_job/2" do
    test "creates a op linked to the mission", %{sector: sector} do
      {:ok, mission} = Missions.create(%{goal: "Quest with ops"})

      assert {:ok, op} =
               Missions.add_job(mission.id, %{title: "Do something", sector_id: sector.id})

      assert op.mission_id == mission.id
      assert op.title == "Do something"
    end
  end
end
