defmodule GiTF.OpsTest do
  use GiTF.StoreCase

  alias GiTF.Ops
  alias GiTF.Archive

  setup do
    {:ok, sector} =
      Archive.insert(:sectors, %{name: "ops-test-sector-#{:erlang.unique_integer([:positive])}"})

    {:ok, mission} =
      Archive.insert(:missions, %{
        name: "ops-test-mission-#{:erlang.unique_integer([:positive])}",
        status: "pending"
      })

    %{sector: sector, mission: mission}
  end

  defp create_job(mission, sector, attrs \\ %{}) do
    default = %{
      title: "Test op #{:erlang.unique_integer([:positive])}",
      mission_id: mission.id,
      sector_id: sector.id
    }

    Ops.create(Map.merge(default, attrs))
  end

  defp create_bee(name \\ nil) do
    name = name || "test-ghost-#{:erlang.unique_integer([:positive])}"
    {:ok, ghost} = Archive.insert(:ghosts, %{name: name, status: "starting"})
    ghost
  end

  describe "create/1" do
    test "creates a op with valid attributes", %{mission: mission, sector: sector} do
      assert {:ok, op} = create_job(mission, sector, %{title: "Build feature"})
      assert op.title == "Build feature"
      assert op.status == "pending"
      assert op.mission_id == mission.id
      assert op.sector_id == sector.id
      assert String.starts_with?(op.id, "op-")
    end

    test "requires title", %{mission: mission, sector: sector} do
      assert {:error, {:missing_fields, [:title]}} =
               Ops.create(%{mission_id: mission.id, sector_id: sector.id})
    end

    test "accepts optional description", %{mission: mission, sector: sector} do
      assert {:ok, op} =
               create_job(mission, sector, %{title: "Work", description: "Detailed instructions"})

      assert op.description == "Detailed instructions"
    end
  end

  describe "get/1" do
    test "retrieves a op by ID", %{mission: mission, sector: sector} do
      {:ok, created} = create_job(mission, sector)
      assert {:ok, found} = Ops.get(created.id)
      assert found.id == created.id
    end

    test "returns error for unknown ID" do
      assert {:error, :not_found} = Ops.get("op-000000")
    end
  end

  describe "list/1" do
    test "returns all ops", %{mission: mission, sector: sector} do
      {:ok, _} = create_job(mission, sector)
      {:ok, _} = create_job(mission, sector)

      ops = Ops.list()
      assert length(ops) >= 2
    end

    test "filters by mission_id", %{mission: mission, sector: sector} do
      {:ok, _} = create_job(mission, sector)

      {:ok, other_quest} =
        Archive.insert(:missions, %{
          name: "other-mission-#{:erlang.unique_integer([:positive])}",
          status: "pending"
        })

      {:ok, _} = create_job(other_quest, sector)

      ops = Ops.list(mission_id: mission.id)
      assert Enum.all?(ops, &(&1.mission_id == mission.id))
    end

    test "filters by status", %{mission: mission, sector: sector} do
      {:ok, _} = create_job(mission, sector)

      pending = Ops.list(status: "pending")
      assert length(pending) >= 1

      done = Ops.list(status: "done")
      assert Enum.all?(done, &(&1.status == "done"))
    end
  end

  describe "status transitions" do
    test "pending -> assigned via assign/2", %{mission: mission, sector: sector} do
      ghost = create_bee()
      {:ok, op} = create_job(mission, sector)
      assert op.status == "pending"

      assert {:ok, assigned} = Ops.assign(op.id, ghost.id)
      assert assigned.status == "assigned"
      assert assigned.ghost_id == ghost.id
    end

    test "assigned -> running via start/1", %{mission: mission, sector: sector} do
      ghost = create_bee()
      {:ok, op} = create_job(mission, sector)
      {:ok, _} = Ops.assign(op.id, ghost.id)

      assert {:ok, running} = Ops.start(op.id)
      assert running.status == "running"
    end

    test "running -> done via complete/1", %{mission: mission, sector: sector} do
      ghost = create_bee()
      {:ok, op} = create_job(mission, sector)
      {:ok, _} = Ops.assign(op.id, ghost.id)
      {:ok, _} = Ops.start(op.id)

      assert {:ok, done} = Ops.complete(op.id)
      assert done.status == "done"
    end

    test "running -> failed via fail/1", %{mission: mission, sector: sector} do
      ghost = create_bee()
      {:ok, op} = create_job(mission, sector)
      {:ok, _} = Ops.assign(op.id, ghost.id)
      {:ok, _} = Ops.start(op.id)

      assert {:ok, failed} = Ops.fail(op.id)
      assert failed.status == "failed"
    end

    test "pending -> blocked via block/1", %{mission: mission, sector: sector} do
      {:ok, op} = create_job(mission, sector)

      assert {:ok, blocked} = Ops.block(op.id)
      assert blocked.status == "blocked"
    end

    test "running -> blocked via block/1", %{mission: mission, sector: sector} do
      ghost = create_bee()
      {:ok, op} = create_job(mission, sector)
      {:ok, _} = Ops.assign(op.id, ghost.id)
      {:ok, _} = Ops.start(op.id)

      assert {:ok, blocked} = Ops.block(op.id)
      assert blocked.status == "blocked"
    end

    test "blocked -> pending via unblock/1", %{mission: mission, sector: sector} do
      {:ok, op} = create_job(mission, sector)
      {:ok, _} = Ops.block(op.id)

      assert {:ok, unblocked} = Ops.unblock(op.id)
      assert unblocked.status == "pending"
    end

    test "failed -> pending via reset/1", %{mission: mission, sector: sector} do
      ghost = create_bee()
      {:ok, op} = create_job(mission, sector)
      {:ok, _} = Ops.assign(op.id, ghost.id)
      {:ok, _} = Ops.start(op.id)
      {:ok, _} = Ops.fail(op.id)

      assert {:ok, reset} = Ops.reset(op.id)
      assert reset.status == "pending"
      assert reset.ghost_id == nil
    end

    test "reset/2 appends feedback to description", %{mission: mission, sector: sector} do
      ghost = create_bee()
      {:ok, op} = create_job(mission, sector, %{description: "Original task"})
      {:ok, _} = Ops.assign(op.id, ghost.id)
      {:ok, _} = Ops.start(op.id)
      {:ok, _} = Ops.fail(op.id)

      assert {:ok, reset} = Ops.reset(op.id, "Validation failed: X is missing")
      assert reset.status == "pending"
      assert String.contains?(reset.description, "Original task")
      assert String.contains?(reset.description, "## Feedback from previous attempt:")
      assert String.contains?(reset.description, "Validation failed: X is missing")
    end
  end

  describe "invalid transitions" do
    test "cannot assign an already assigned op", %{mission: mission, sector: sector} do
      bee1 = create_bee()
      bee2 = create_bee()
      {:ok, op} = create_job(mission, sector)
      {:ok, _} = Ops.assign(op.id, bee1.id)

      assert {:error, :invalid_transition} = Ops.assign(op.id, bee2.id)
    end

    test "cannot start a pending op", %{mission: mission, sector: sector} do
      {:ok, op} = create_job(mission, sector)
      assert {:error, :invalid_transition} = Ops.start(op.id)
    end

    test "cannot complete a pending op", %{mission: mission, sector: sector} do
      {:ok, op} = create_job(mission, sector)
      assert {:error, :invalid_transition} = Ops.complete(op.id)
    end

    test "cannot fail a pending op", %{mission: mission, sector: sector} do
      {:ok, op} = create_job(mission, sector)
      assert {:error, :invalid_transition} = Ops.fail(op.id)
    end

    test "cannot unblock a pending op", %{mission: mission, sector: sector} do
      {:ok, op} = create_job(mission, sector)
      assert {:error, :invalid_transition} = Ops.unblock(op.id)
    end

    test "cannot block a done op", %{mission: mission, sector: sector} do
      ghost = create_bee()
      {:ok, op} = create_job(mission, sector)
      {:ok, _} = Ops.assign(op.id, ghost.id)
      {:ok, _} = Ops.start(op.id)
      {:ok, _} = Ops.complete(op.id)

      assert {:error, :invalid_transition} = Ops.block(op.id)
    end

    test "cannot reset a pending op", %{mission: mission, sector: sector} do
      {:ok, op} = create_job(mission, sector)
      assert {:error, :invalid_transition} = Ops.reset(op.id)
    end

    test "cannot reset a running op", %{mission: mission, sector: sector} do
      ghost = create_bee()
      {:ok, op} = create_job(mission, sector)
      {:ok, _} = Ops.assign(op.id, ghost.id)
      {:ok, _} = Ops.start(op.id)

      assert {:error, :invalid_transition} = Ops.reset(op.id)
    end
  end
end
