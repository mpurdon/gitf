defmodule GiTF.QuestsTest do
  use ExUnit.Case, async: false

  alias GiTF.Quests
  alias GiTF.Store

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "gitf_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Store.start_link(data_dir: tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, comb} =
      Store.insert(:combs, %{name: "quests-test-comb-#{:erlang.unique_integer([:positive])}"})

    %{comb: comb}
  end

  describe "create/1" do
    test "creates a quest with a goal and auto-generates name" do
      assert {:ok, quest} = Quests.create(%{goal: "Refactor the auth module"})
      assert quest.goal == "Refactor the auth module"
      assert quest.name == "refactor-the-auth-module"
      assert quest.status == "pending"
      assert String.starts_with?(quest.id, "qst-")
    end

    test "accepts optional comb_id", %{comb: comb} do
      assert {:ok, quest} = Quests.create(%{goal: "Build feature", comb_id: comb.id})
      assert quest.comb_id == comb.id
    end

    test "accepts explicit name override" do
      assert {:ok, quest} = Quests.create(%{goal: "Do the thing", name: "custom-name"})
      assert quest.name == "custom-name"
      assert quest.goal == "Do the thing"
    end

    test "requires goal" do
      assert {:error, {:missing_fields, [:goal]}} = Quests.create(%{})
    end
  end

  describe "get/1" do
    test "retrieves a quest by ID and preloads jobs" do
      {:ok, quest} = Quests.create(%{goal: "Find quest"})

      assert {:ok, found} = Quests.get(quest.id)
      assert found.id == quest.id
      assert found.jobs == []
    end

    test "returns error for unknown ID" do
      assert {:error, :not_found} = Quests.get("qst-000000")
    end
  end

  describe "list/1" do
    test "returns all quests" do
      {:ok, _} = Quests.create(%{goal: "Quest 1"})
      {:ok, _} = Quests.create(%{goal: "Quest 2"})

      quests = Quests.list()
      assert length(quests) >= 2
    end

    test "filters by status" do
      {:ok, _} = Quests.create(%{goal: "Pending quest"})
      {:ok, q} = Quests.create(%{goal: "Active quest"})

      Store.put(:quests, %{q | status: "active"})

      pending = Quests.list(status: "pending")
      assert Enum.all?(pending, &(&1.status == "pending"))

      active = Quests.list(status: "active")
      assert length(active) >= 1
    end
  end

  describe "compute_status/1" do
    test "returns pending for empty job list" do
      assert Quests.compute_status([]) == "pending"
    end

    test "returns pending when all jobs are pending" do
      assert Quests.compute_status(["pending", "pending"]) == "pending"
    end

    test "returns completed when all jobs are done" do
      assert Quests.compute_status(["done", "done", "done"]) == "completed"
    end

    test "returns failed when any job has failed" do
      assert Quests.compute_status(["done", "failed", "pending"]) == "failed"
    end

    test "returns active when any job is running" do
      assert Quests.compute_status(["done", "running", "pending"]) == "active"
    end

    test "returns active when any job is assigned" do
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
    test "recomputes status from job statuses", %{comb: comb} do
      {:ok, quest} = Quests.create(%{goal: "Update status quest"})

      {:ok, _} =
        GiTF.Jobs.create(%{
          title: "Done job",
          quest_id: quest.id,
          comb_id: comb.id,
          status: "done"
        })

      {:ok, _} =
        GiTF.Jobs.create(%{
          title: "Running job",
          quest_id: quest.id,
          comb_id: comb.id,
          status: "running"
        })

      assert {:ok, updated} = Quests.update_status!(quest.id)
      assert updated.status == "active"
    end

    test "sets completed when all jobs done", %{comb: comb} do
      {:ok, quest} = Quests.create(%{goal: "Complete quest"})

      {:ok, _} =
        GiTF.Jobs.create(%{
          title: "Job 1",
          quest_id: quest.id,
          comb_id: comb.id,
          status: "done"
        })

      {:ok, _} =
        GiTF.Jobs.create(%{
          title: "Job 2",
          quest_id: quest.id,
          comb_id: comb.id,
          status: "done"
        })

      assert {:ok, updated} = Quests.update_status!(quest.id)
      assert updated.status == "completed"
    end
  end

  describe "close/1" do
    test "sets quest status to closed", %{comb: comb} do
      {:ok, quest} = Quests.create(%{goal: "Close me", comb_id: comb.id})

      assert {:ok, closed} = Quests.close(quest.id)
      assert closed.status == "closed"

      # Verify persisted
      assert {:ok, fetched} = Quests.get(quest.id)
      assert fetched.status == "closed"
    end

    test "closes quest with jobs that have no ghosts", %{comb: comb} do
      {:ok, quest} = Quests.create(%{goal: "Quest with unassigned jobs"})

      {:ok, _job} =
        GiTF.Jobs.create(%{title: "Unassigned job", quest_id: quest.id, comb_id: comb.id})

      assert {:ok, closed} = Quests.close(quest.id)
      assert closed.status == "closed"
    end

    test "attempts to remove active cells for assigned ghosts", %{comb: comb} do
      {:ok, quest} = Quests.create(%{goal: "Quest with ghosts"})

      {:ok, job} =
        GiTF.Jobs.create(%{
          title: "Job with ghost",
          quest_id: quest.id,
          comb_id: comb.id,
          status: "done"
        })

      {:ok, ghost} = Store.insert(:ghosts, %{name: "test-ghost", job_id: job.id, status: "stopped"})
      GiTF.Jobs.assign(job.id, ghost.id)

      {:ok, _cell} =
        Store.insert(:cells, %{
          ghost_id: ghost.id,
          comb_id: comb.id,
          worktree_path: "/tmp/fake-worktree-#{ghost.id}",
          branch: "ghost/#{ghost.id}",
          status: "active"
        })

      # close/1 will attempt Cell.remove which may fail on fake worktree,
      # but quest status should still be set to "closed"
      assert {:ok, closed} = Quests.close(quest.id)
      assert closed.status == "closed"
    end

    test "returns error for unknown quest" do
      assert {:error, :not_found} = Quests.close("qst-nonexistent")
    end
  end

  describe "set_planning/1" do
    test "transitions pending quest to planning" do
      {:ok, quest} = Quests.create(%{goal: "Plan this"})
      assert quest.status == "pending"

      assert {:ok, updated} = Quests.set_planning(quest.id)
      assert updated.status == "planning"
    end

    test "rejects transition from non-pending status" do
      {:ok, quest} = Quests.create(%{goal: "Already active"})
      Store.put(:quests, %{quest | status: "active"})

      assert {:error, :invalid_transition} = Quests.set_planning(quest.id)
    end

    test "rejects transition from planning (idempotent guard)" do
      {:ok, quest} = Quests.create(%{goal: "Already planning"})
      {:ok, _} = Quests.set_planning(quest.id)

      assert {:error, :invalid_transition} = Quests.set_planning(quest.id)
    end

    test "returns not_found for unknown quest" do
      assert {:error, :not_found} = Quests.set_planning("qst-nonexistent")
    end
  end

  describe "update_status!/1 with planning" do
    test "preserves planning status when quest has no jobs" do
      {:ok, quest} = Quests.create(%{goal: "Planning quest"})
      {:ok, _} = Quests.set_planning(quest.id)

      assert {:ok, updated} = Quests.update_status!(quest.id)
      assert updated.status == "planning"
    end

    test "computes status normally once planning quest has jobs", %{comb: comb} do
      {:ok, quest} = Quests.create(%{goal: "Planning with jobs"})
      {:ok, _} = Quests.set_planning(quest.id)

      {:ok, _} =
        GiTF.Jobs.create(%{
          title: "First job",
          quest_id: quest.id,
          comb_id: comb.id,
          status: "running"
        })

      assert {:ok, updated} = Quests.update_status!(quest.id)
      assert updated.status == "active"
    end
  end

  describe "add_job/2" do
    test "creates a job linked to the quest", %{comb: comb} do
      {:ok, quest} = Quests.create(%{goal: "Quest with jobs"})

      assert {:ok, job} =
               Quests.add_job(quest.id, %{title: "Do something", comb_id: comb.id})

      assert job.quest_id == quest.id
      assert job.title == "Do something"
    end
  end
end
