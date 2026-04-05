defmodule GiTF.OpsDepTest do
  use ExUnit.Case, async: false

  alias GiTF.Ops
  alias GiTF.Archive

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "gitf_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Archive.start_link(data_dir: tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, sector} =
      Archive.insert(:sectors, %{name: "dep-test-sector-#{:erlang.unique_integer([:positive])}"})

    {:ok, mission} =
      Archive.insert(:missions, %{
        name: "dep-test-mission-#{:erlang.unique_integer([:positive])}",
        status: "pending"
      })

    %{sector: sector, mission: mission}
  end

  defp create_job(mission, sector, title \\ nil) do
    title = title || "Job #{:erlang.unique_integer([:positive])}"
    Ops.create(%{title: title, mission_id: mission.id, sector_id: sector.id})
  end

  defp create_bee do
    {:ok, ghost} =
      Archive.insert(:ghosts, %{
        name: "test-ghost-#{:erlang.unique_integer([:positive])}",
        status: "starting"
      })

    ghost
  end

  describe "add_dependency/2" do
    test "adds a dependency between two ops", %{mission: q, sector: c} do
      {:ok, job_a} = create_job(q, c, "Job A")
      {:ok, job_b} = create_job(q, c, "Job B")

      assert {:ok, dep} = Ops.add_dependency(job_b.id, job_a.id)
      assert dep.op_id == job_b.id
      assert dep.depends_on_id == job_a.id
      assert String.starts_with?(dep.id, "dep-")
    end

    test "rejects self-dependency", %{mission: q, sector: c} do
      {:ok, op} = create_job(q, c)
      assert {:error, :self_dependency} = Ops.add_dependency(op.id, op.id)
    end

    test "rejects cycles", %{mission: q, sector: c} do
      {:ok, a} = create_job(q, c, "A")
      {:ok, b} = create_job(q, c, "B")
      {:ok, cc} = create_job(q, c, "C")

      # A -> B -> C, then trying C -> A should fail
      {:ok, _} = Ops.add_dependency(a.id, b.id)
      {:ok, _} = Ops.add_dependency(b.id, cc.id)
      assert {:error, :cycle_detected} = Ops.add_dependency(cc.id, a.id)
    end

    test "rejects direct cycle (A->B, B->A)", %{mission: q, sector: c} do
      {:ok, a} = create_job(q, c, "A")
      {:ok, b} = create_job(q, c, "B")

      {:ok, _} = Ops.add_dependency(a.id, b.id)
      assert {:error, :cycle_detected} = Ops.add_dependency(b.id, a.id)
    end
  end

  describe "remove_dependency/2" do
    test "removes an existing dependency", %{mission: q, sector: c} do
      {:ok, a} = create_job(q, c)
      {:ok, b} = create_job(q, c)
      {:ok, _} = Ops.add_dependency(a.id, b.id)

      assert :ok = Ops.remove_dependency(a.id, b.id)
      assert Ops.dependencies(a.id) == []
    end

    test "returns error for non-existent dependency", %{mission: q, sector: c} do
      {:ok, a} = create_job(q, c)
      {:ok, b} = create_job(q, c)

      assert {:error, :not_found} = Ops.remove_dependency(a.id, b.id)
    end
  end

  describe "dependencies/1 and dependents/1" do
    test "lists dependencies and dependents", %{mission: q, sector: c} do
      {:ok, a} = create_job(q, c, "A")
      {:ok, b} = create_job(q, c, "B")
      {:ok, cc} = create_job(q, c, "C")

      {:ok, _} = Ops.add_dependency(cc.id, a.id)
      {:ok, _} = Ops.add_dependency(cc.id, b.id)

      deps = Ops.dependencies(cc.id)
      assert length(deps) == 2
      dep_ids = Enum.map(deps, & &1.id) |> Enum.sort()
      assert dep_ids == Enum.sort([a.id, b.id])

      dependents_of_a = Ops.dependents(a.id)
      assert length(dependents_of_a) == 1
      assert hd(dependents_of_a).id == cc.id
    end
  end

  describe "ready?/1" do
    test "returns true when no dependencies", %{mission: q, sector: c} do
      {:ok, op} = create_job(q, c)
      assert Ops.ready?(op.id) == true
    end

    test "returns false when dependency is not done", %{mission: q, sector: c} do
      {:ok, a} = create_job(q, c, "A")
      {:ok, b} = create_job(q, c, "B")
      {:ok, _} = Ops.add_dependency(b.id, a.id)

      assert Ops.ready?(b.id) == false
    end

    test "returns true when all dependencies are done", %{mission: q, sector: c} do
      ghost = create_bee()
      {:ok, a} = create_job(q, c, "A")
      {:ok, b} = create_job(q, c, "B")
      {:ok, _} = Ops.add_dependency(b.id, a.id)

      # Complete op A
      {:ok, _} = Ops.assign(a.id, ghost.id)
      {:ok, _} = Ops.start(a.id)
      {:ok, _} = Ops.complete(a.id)

      assert Ops.ready?(b.id) == true
    end
  end

  describe "unblock_dependents/1" do
    test "unblocks blocked dependents when all deps done", %{mission: q, sector: c} do
      ghost = create_bee()
      {:ok, a} = create_job(q, c, "A")
      {:ok, b} = create_job(q, c, "B")
      {:ok, _} = Ops.add_dependency(b.id, a.id)

      # Complete A
      {:ok, _} = Ops.assign(a.id, ghost.id)
      {:ok, _} = Ops.start(a.id)
      {:ok, _} = Ops.complete(a.id)

      :ok = Ops.unblock_dependents(a.id)

      {:ok, b_updated} = Ops.get(b.id)
      assert b_updated.status == "pending"
    end

    test "does not unblock when other deps remain", %{mission: q, sector: c} do
      ghost = create_bee()
      {:ok, a} = create_job(q, c, "A")
      {:ok, b} = create_job(q, c, "B")
      {:ok, cc} = create_job(q, c, "C")

      {:ok, _} = Ops.add_dependency(cc.id, a.id)
      {:ok, _} = Ops.add_dependency(cc.id, b.id)

      # Complete A
      {:ok, _} = Ops.assign(a.id, ghost.id)
      {:ok, _} = Ops.start(a.id)
      {:ok, _} = Ops.complete(a.id)

      :ok = Ops.unblock_dependents(a.id)

      {:ok, cc_updated} = Ops.get(cc.id)
      assert cc_updated.status == "blocked"
    end
  end

  describe "blocked spawn rejection" do
    test "Ghosts.spawn returns :blocked when deps not ready", %{mission: q, sector: c} do
      {:ok, a} = create_job(q, c, "A")
      {:ok, b} = create_job(q, c, "B")
      {:ok, _} = Ops.add_dependency(b.id, a.id)

      assert {:error, :blocked} = GiTF.Ghosts.spawn(b.id, c.id, "/tmp/fake_gitf")
    end
  end
end
