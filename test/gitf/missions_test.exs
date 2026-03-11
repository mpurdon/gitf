defmodule GiTF.QuestsTest do
  use ExUnit.Case, async: false

  alias GiTF.Missions
  alias GiTF.Archive

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "gitf_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Archive.start_link(data_dir: tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, sector} =
      Archive.insert(:sectors, %{name: "missions-test-sector-#{:erlang.unique_integer([:positive])}"})

    %{sector: sector}
  end

  describe "create/1" do
    test "creates a mission with a goal and auto-generates name" do
      assert {:ok, mission} = Quests.create(%{goal: "Refactor the auth module"})
      assert mission.goal == "Refactor the auth module"
      assert mission.name == "refactor-the-auth-module"
      assert mission.status == "pending"
      assert String.starts_with?(mission.id, "qst-")
    end

    test "accepts optional sector_id", %{sector: sector} do
      assert {:ok, mission} = Quests.create(%{goal: "Build feature", sector_id: sector.id})
      assert mission.sector_id == sector.id
    end

    test "accepts explicit name override" do
      assert {:ok, mission} = Quests.create(%{goal: "Do the thing", name: "custom-name"})
      assert mission.name == "custom-name"
      assert mission.goal == "Do the thing"
    end

    test "requires goal" do
      assert {:error, {:missing_fields, [:goal]}} = Quests.create(%{})
    end
  end

  describe "get/1" do
    test "retrieves a mission by ID and preloads ops" do
      {:ok, mission} = Quests.create(%{goal: "Find mission"})

      assert {:ok, found} = Quests.get(mission.id)
      assert found.id == mission.id
      assert found.ops == []
    end

    test "returns error for unknown ID" do
      assert {:error, :not_found} = Quests.get("qst-000000")
    end
  end

  describe "list/1" do
    test "returns all missions" do
      {:ok, _} = Quests.create(%{goal: "Quest 1"})
      {:ok, _} = Quests.create(%{goal: "Quest 2"})

      missions = Quests.list()
      assert length(missions) >= 2
    end

    test "filters by status" do
      {:ok, _} = Quests.create(%{goal: "Pending mission"})
      {:ok, q} = Quests.create(%{goal: "Active mission"})

      Archive.put(:missions, %{q | status: "active"})

      pending = Quests.list(status: "pending")
      assert Enum.all?(pending, &(&1.status == "pending"))

      active = Quests.list(status: "active")
      assert length(active) >= 1
    end
  end

  describe "compute_status/1" do
    test "returns pending for empty op list" do
      assert Quests.compute_status([]) == "pending"
    end

    test "returns pending when all ops are pending" do
      assert Quests.compute_status(["pending", "pending"]) == "pending"
    end

    test "returns completed when all ops are done" do
      assert Quests.compute_status(["done", "done", "done"]) == "completed"
    end

    test "returns failed when any op has failed" do
      assert Quests.compute_status(["done", "failed", "pending"]) == "failed"
    end

    test "returns active when any op is running" do
      assert Quests.compute_status(["done", "running", "pending"]) == "active"
    end

    test "returns active when any op is assigned" do
      assert Quests.compute_status(["pending", "assigned"]) == "active"
    end

    test "returns pending for mixed pending and blocked" do
      assert Quests.compute_status(["pending", "blocked"]) == "pending"
    end

    test "failed takes precedence over active" do
      assert Quests.compute_status(["running", "failed"]) == "failed"
    end
  end

  describe "update_status!/1" do
    test "recomputes status from op statuses", %{sector: sector} do
      {:ok, mission} = Quests.create(%{goal: "Update status mission"})

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

      assert {:ok, updated} = Quests.update_status!(mission.id)
      assert updated.status == "active"
    end

    test "sets completed when all ops done", %{sector: sector} do
      {:ok, mission} = Quests.create(%{goal: "Complete mission"})

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

      assert {:ok, updated} = Quests.update_status!(mission.id)
      assert updated.status == "completed"
    end
  end

  describe "close/1" do
    test "sets mission status to closed", %{sector: sector} do
      {:ok, mission} = Quests.create(%{goal: "Close me", sector_id: sector.id})

      assert {:ok, closed} = Quests.close(mission.id)
      assert closed.status == "closed"

      # Verify persisted
      assert {:ok, fetched} = Quests.get(mission.id)
      assert fetched.status == "closed"
    end

    test "closes mission with ops that have no ghosts", %{sector: sector} do
      {:ok, mission} = Quests.create(%{goal: "Quest with unassigned ops"})

      {:ok, _job} =
        GiTF.Ops.create(%{title: "Unassigned op", mission_id: mission.id, sector_id: sector.id})

      assert {:ok, closed} = Quests.close(mission.id)
      assert closed.status == "closed"
    end

    test "attempts to remove active shells for assigned ghosts", %{sector: sector} do
      {:ok, mission} = Quests.create(%{goal: "Quest with ghosts"})

      {:ok, op} =
        GiTF.Ops.create(%{
          title: "Job with ghost",
          mission_id: mission.id,
          sector_id: sector.id,
          status: "done"
        })

      {:ok, ghost} = Archive.insert(:ghosts, %{name: "test-ghost", op_id: op.id, status: "stopped"})
      GiTF.Ops.assign(op.id, ghost.id)

      {:ok, _cell} =
        Archive.insert(:shells, %{
          ghost_id: ghost.id,
          sector_id: sector.id,
          worktree_path: "/tmp/fake-worktree-#{ghost.id}",
          branch: "ghost/#{ghost.id}",
          status: "active"
        })

      # close/1 will attempt Cell.remove which may fail on fake worktree,
      # but mission status should still be set to "closed"
      assert {:ok, closed} = Quests.close(mission.id)
      assert closed.status == "closed"
    end

    test "returns error for unknown mission" do
      assert {:error, :not_found} = Quests.close("qst-nonexistent")
    end
  end

  describe "set_planning/1" do
    test "transitions pending mission to planning" do
      {:ok, mission} = Quests.create(%{goal: "Plan this"})
      assert mission.status == "pending"

      assert {:ok, updated} = Quests.set_planning(mission.id)
      assert updated.status == "planning"
    end

    test "rejects transition from non-pending status" do
      {:ok, mission} = Quests.create(%{goal: "Already active"})
      Archive.put(:missions, %{mission | status: "active"})

      assert {:error, :invalid_transition} = Quests.set_planning(mission.id)
    end

    test "rejects transition from planning (idempotent guard)" do
      {:ok, mission} = Quests.create(%{goal: "Already planning"})
      {:ok, _} = Quests.set_planning(mission.id)

      assert {:error, :invalid_transition} = Quests.set_planning(mission.id)
    end

    test "returns not_found for unknown mission" do
      assert {:error, :not_found} = Quests.set_planning("qst-nonexistent")
    end
  end

  describe "update_status!/1 with planning" do
    test "preserves planning status when mission has no ops" do
      {:ok, mission} = Quests.create(%{goal: "Planning mission"})
      {:ok, _} = Quests.set_planning(mission.id)

      assert {:ok, updated} = Quests.update_status!(mission.id)
      assert updated.status == "planning"
    end

    test "computes status normally once planning mission has ops", %{sector: sector} do
      {:ok, mission} = Quests.create(%{goal: "Planning with ops"})
      {:ok, _} = Quests.set_planning(mission.id)

      {:ok, _} =
        GiTF.Ops.create(%{
          title: "First op",
          mission_id: mission.id,
          sector_id: sector.id,
          status: "running"
        })

      assert {:ok, updated} = Quests.update_status!(mission.id)
      assert updated.status == "active"
    end
  end

  describe "add_job/2" do
    test "creates a op linked to the mission", %{sector: sector} do
      {:ok, mission} = Quests.create(%{goal: "Quest with ops"})

      assert {:ok, op} =
               Quests.add_job(mission.id, %{title: "Do something", sector_id: sector.id})

      assert op.mission_id == mission.id
      assert op.title == "Do something"
    end
  end
end
