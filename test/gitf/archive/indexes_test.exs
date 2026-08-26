defmodule GiTF.Archive.IndexesTest do
  @moduledoc "Tests for Archive secondary indexes."

  use ExUnit.Case, async: false

  alias GiTF.Archive
  alias GiTF.Archive.Indexes

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    store_dir =
      Path.join(
        System.tmp_dir!(),
        "gitf_idx_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(store_dir)
    GiTF.Test.StoreHelper.stop_store()

    try do
      :ets.delete(:gitf_store_cache)
    rescue
      ArgumentError -> :ok
    end

    {:ok, _pid} = Archive.start_link(data_dir: store_dir)

    on_exit(fn ->
      GiTF.Test.StoreHelper.stop_store()

      try do
        :ets.delete(:gitf_store_cache)
      rescue
        ArgumentError -> :ok
      end

      File.rm_rf!(store_dir)
      GiTF.Test.StoreHelper.restore_app_store()
    end)

    %{store_dir: store_dir}
  end

  describe "insert + lookup" do
    test "by_index returns only matching records by status" do
      {:ok, p1} = Archive.insert(:ops, %{status: "pending", mission_id: "msn-1"})
      {:ok, _r1} = Archive.insert(:ops, %{status: "running", mission_id: "msn-1"})
      {:ok, p2} = Archive.insert(:ops, %{status: "pending", mission_id: "msn-2"})

      pending = Archive.by_index(:ops, :status, "pending")
      ids = Enum.map(pending, & &1.id) |> Enum.sort()

      assert length(pending) == 2
      assert ids == Enum.sort([p1.id, p2.id])
    end

    test "by_index returns matching records by mission_id" do
      {:ok, a1} = Archive.insert(:ops, %{status: "pending", mission_id: "msn-A"})
      {:ok, a2} = Archive.insert(:ops, %{status: "running", mission_id: "msn-A"})
      {:ok, _b1} = Archive.insert(:ops, %{status: "pending", mission_id: "msn-B"})

      results = Archive.by_index(:ops, :mission_id, "msn-A")
      ids = Enum.map(results, & &1.id) |> Enum.sort()

      assert length(results) == 2
      assert ids == Enum.sort([a1.id, a2.id])
    end
  end

  describe "update changing indexed value" do
    test "old index cleared, new index populated" do
      {:ok, op} = Archive.insert(:ops, %{status: "pending", mission_id: "msn-1"})

      {:ok, _updated} =
        Archive.update(:ops, op.id, fn r -> Map.put(r, :status, "running") end)

      assert Archive.by_index(:ops, :status, "pending") == []
      running = Archive.by_index(:ops, :status, "running")
      assert length(running) == 1
      assert hd(running).id == op.id
    end
  end

  describe "delete removes from index" do
    test "deleted record no longer appears in index" do
      {:ok, op} = Archive.insert(:ops, %{status: "pending", mission_id: "msn-1"})
      assert length(Archive.by_index(:ops, :status, "pending")) == 1

      :ok = Archive.delete(:ops, op.id)
      assert Archive.by_index(:ops, :status, "pending") == []
    end
  end

  describe "count_by_index" do
    test "matches length of by_index" do
      {:ok, _} = Archive.insert(:ops, %{status: "pending", mission_id: "msn-1"})
      {:ok, _} = Archive.insert(:ops, %{status: "pending", mission_id: "msn-2"})
      {:ok, _} = Archive.insert(:ops, %{status: "done", mission_id: "msn-1"})

      assert Archive.count_by_index(:ops, :status, "pending") == 2
      assert Archive.count_by_index(:ops, :status, "done") == 1

      assert Archive.count_by_index(:ops, :status, "pending") ==
               length(Archive.by_index(:ops, :status, "pending"))
    end
  end

  describe "by_index equals filter" do
    test "by_index returns same set as filter for indexed fields" do
      {:ok, _} = Archive.insert(:ops, %{status: "pending", mission_id: "msn-X"})
      {:ok, _} = Archive.insert(:ops, %{status: "running", mission_id: "msn-X"})
      {:ok, _} = Archive.insert(:ops, %{status: "pending", mission_id: "msn-Y"})

      for {field, value} <- [{:status, "pending"}, {:mission_id, "msn-X"}] do
        indexed = Archive.by_index(:ops, field, value) |> Enum.sort_by(& &1.id)
        filtered = Archive.filter(:ops, &(Map.get(&1, field) == value)) |> Enum.sort_by(& &1.id)
        assert indexed == filtered
      end
    end
  end

  describe "non-indexed collection/field" do
    test "by_index returns empty list without crash" do
      {:ok, _} = Archive.insert(:missions, %{name: "test"})
      assert Archive.by_index(:missions, :name, "test") == []
    end

    test "count_by_index returns 0 without crash" do
      assert Archive.count_by_index(:missions, :name, "test") == 0
    end
  end

  describe "index survives Archive restart" do
    test "by_index works after stop and restart", %{store_dir: store_dir} do
      {:ok, op} = Archive.insert(:ops, %{status: "pending", mission_id: "msn-1"})
      # Async persistence: flush so the restart recovers from disk.
      :ok = Archive.flush()

      GiTF.Test.StoreHelper.stop_store()
      {:ok, _} = Archive.start_link(data_dir: store_dir)

      results = Archive.by_index(:ops, :status, "pending")
      assert length(results) == 1
      assert hd(results).id == op.id
    end
  end

  describe "op_dependencies indexes" do
    test "lookup by op_id and depends_on_id" do
      {:ok, dep} =
        Archive.insert(:op_dependencies, %{
          op_id: "op-1",
          depends_on_id: "op-2"
        })

      assert [found] = Archive.by_index(:op_dependencies, :op_id, "op-1")
      assert found.id == dep.id

      assert [found] = Archive.by_index(:op_dependencies, :depends_on_id, "op-2")
      assert found.id == dep.id

      assert Archive.by_index(:op_dependencies, :op_id, "op-99") == []
    end
  end

  describe "update maintains indexes incrementally" do
    test "index reflects the new value and drops the old after update/3" do
      {:ok, op} = Archive.insert(:ops, %{status: "pending", mission_id: "msn-1"})
      assert length(Archive.by_index(:ops, :status, "pending")) == 1

      {:ok, _} = Archive.update(:ops, op.id, fn o -> %{o | status: "blocked"} end)

      # Incremental index diff: old value removed, new value added — no full
      # rebuild.
      assert Archive.by_index(:ops, :status, "pending") == []
      assert length(Archive.by_index(:ops, :status, "blocked")) == 1
    end
  end

  describe "Indexes module directly" do
    test "init_tables is idempotent" do
      assert :ok = Indexes.init_tables()
      assert :ok = Indexes.init_tables()
    end

    test "clear_tables and delete_tables don't crash on missing tables" do
      assert :ok = Indexes.clear_tables()
      assert :ok = Indexes.delete_tables()
    end
  end
end
