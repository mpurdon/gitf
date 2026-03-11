defmodule GiTF.JobsDepTest do
  use ExUnit.Case, async: false

  alias GiTF.Jobs
  alias GiTF.Store

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "gitf_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Store.start_link(data_dir: tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, comb} =
      Store.insert(:combs, %{name: "dep-test-comb-#{:erlang.unique_integer([:positive])}"})

    {:ok, quest} =
      Store.insert(:quests, %{
        name: "dep-test-quest-#{:erlang.unique_integer([:positive])}",
        status: "pending"
      })

    %{comb: comb, quest: quest}
  end

  defp create_job(quest, comb, title \\ nil) do
    title = title || "Job #{:erlang.unique_integer([:positive])}"
    Jobs.create(%{title: title, quest_id: quest.id, comb_id: comb.id})
  end

  defp create_bee do
    {:ok, ghost} =
      Store.insert(:ghosts, %{
        name: "test-ghost-#{:erlang.unique_integer([:positive])}",
        status: "starting"
      })

    ghost
  end

  describe "add_dependency/2" do
    test "adds a dependency between two jobs", %{quest: q, comb: c} do
      {:ok, job_a} = create_job(q, c, "Job A")
      {:ok, job_b} = create_job(q, c, "Job B")

      assert {:ok, dep} = Jobs.add_dependency(job_b.id, job_a.id)
      assert dep.job_id == job_b.id
      assert dep.depends_on_id == job_a.id
      assert String.starts_with?(dep.id, "jdp-")
    end

    test "rejects self-dependency", %{quest: q, comb: c} do
      {:ok, job} = create_job(q, c)
      assert {:error, :self_dependency} = Jobs.add_dependency(job.id, job.id)
    end

    test "rejects cycles", %{quest: q, comb: c} do
      {:ok, a} = create_job(q, c, "A")
      {:ok, b} = create_job(q, c, "B")
      {:ok, cc} = create_job(q, c, "C")

      # A -> B -> C, then trying C -> A should fail
      {:ok, _} = Jobs.add_dependency(a.id, b.id)
      {:ok, _} = Jobs.add_dependency(b.id, cc.id)
      assert {:error, :cycle_detected} = Jobs.add_dependency(cc.id, a.id)
    end

    test "rejects direct cycle (A->B, B->A)", %{quest: q, comb: c} do
      {:ok, a} = create_job(q, c, "A")
      {:ok, b} = create_job(q, c, "B")

      {:ok, _} = Jobs.add_dependency(a.id, b.id)
      assert {:error, :cycle_detected} = Jobs.add_dependency(b.id, a.id)
    end
  end

  describe "remove_dependency/2" do
    test "removes an existing dependency", %{quest: q, comb: c} do
      {:ok, a} = create_job(q, c)
      {:ok, b} = create_job(q, c)
      {:ok, _} = Jobs.add_dependency(a.id, b.id)

      assert :ok = Jobs.remove_dependency(a.id, b.id)
      assert Jobs.dependencies(a.id) == []
    end

    test "returns error for non-existent dependency", %{quest: q, comb: c} do
      {:ok, a} = create_job(q, c)
      {:ok, b} = create_job(q, c)

      assert {:error, :not_found} = Jobs.remove_dependency(a.id, b.id)
    end
  end

  describe "dependencies/1 and dependents/1" do
    test "lists dependencies and dependents", %{quest: q, comb: c} do
      {:ok, a} = create_job(q, c, "A")
      {:ok, b} = create_job(q, c, "B")
      {:ok, cc} = create_job(q, c, "C")

      {:ok, _} = Jobs.add_dependency(cc.id, a.id)
      {:ok, _} = Jobs.add_dependency(cc.id, b.id)

      deps = Jobs.dependencies(cc.id)
      assert length(deps) == 2
      dep_ids = Enum.map(deps, & &1.id) |> Enum.sort()
      assert dep_ids == Enum.sort([a.id, b.id])

      dependents_of_a = Jobs.dependents(a.id)
      assert length(dependents_of_a) == 1
      assert hd(dependents_of_a).id == cc.id
    end
  end

  describe "ready?/1" do
    test "returns true when no dependencies", %{quest: q, comb: c} do
      {:ok, job} = create_job(q, c)
      assert Jobs.ready?(job.id) == true
    end

    test "returns false when dependency is not done", %{quest: q, comb: c} do
      {:ok, a} = create_job(q, c, "A")
      {:ok, b} = create_job(q, c, "B")
      {:ok, _} = Jobs.add_dependency(b.id, a.id)

      assert Jobs.ready?(b.id) == false
    end

    test "returns true when all dependencies are done", %{quest: q, comb: c} do
      ghost = create_bee()
      {:ok, a} = create_job(q, c, "A")
      {:ok, b} = create_job(q, c, "B")
      {:ok, _} = Jobs.add_dependency(b.id, a.id)

      # Complete job A
      {:ok, _} = Jobs.assign(a.id, ghost.id)
      {:ok, _} = Jobs.start(a.id)
      {:ok, _} = Jobs.complete(a.id)

      assert Jobs.ready?(b.id) == true
    end
  end

  describe "unblock_dependents/1" do
    test "unblocks blocked dependents when all deps done", %{quest: q, comb: c} do
      ghost = create_bee()
      {:ok, a} = create_job(q, c, "A")
      {:ok, b} = create_job(q, c, "B")
      {:ok, _} = Jobs.add_dependency(b.id, a.id)
      {:ok, _} = Jobs.block(b.id)

      # Complete A
      {:ok, _} = Jobs.assign(a.id, ghost.id)
      {:ok, _} = Jobs.start(a.id)
      {:ok, _} = Jobs.complete(a.id)

      :ok = Jobs.unblock_dependents(a.id)

      {:ok, b_updated} = Jobs.get(b.id)
      assert b_updated.status == "pending"
    end

    test "does not unblock when other deps remain", %{quest: q, comb: c} do
      ghost = create_bee()
      {:ok, a} = create_job(q, c, "A")
      {:ok, b} = create_job(q, c, "B")
      {:ok, cc} = create_job(q, c, "C")

      {:ok, _} = Jobs.add_dependency(cc.id, a.id)
      {:ok, _} = Jobs.add_dependency(cc.id, b.id)
      {:ok, _} = Jobs.block(cc.id)

      # Complete only A
      {:ok, _} = Jobs.assign(a.id, ghost.id)
      {:ok, _} = Jobs.start(a.id)
      {:ok, _} = Jobs.complete(a.id)

      :ok = Jobs.unblock_dependents(a.id)

      {:ok, cc_updated} = Jobs.get(cc.id)
      assert cc_updated.status == "blocked"
    end
  end

  describe "blocked spawn rejection" do
    test "Ghosts.spawn returns :blocked when deps not ready", %{quest: q, comb: c} do
      {:ok, a} = create_job(q, c, "A")
      {:ok, b} = create_job(q, c, "B")
      {:ok, _} = Jobs.add_dependency(b.id, a.id)

      assert {:error, :blocked} = GiTF.Ghosts.spawn(b.id, c.id, "/tmp/fake_gitf")
    end
  end
end
