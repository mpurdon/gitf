defmodule GiTF.ArchiveTest do
  @moduledoc """
  Characterization tests for GiTF.Archive.

  Exercises the full CRUD surface, atomic update/3 contract,
  bulk operations, transact/1, lock serialization, backup recovery,
  persistence across restarts, and collection isolation.
  """

  use ExUnit.Case, async: false

  alias GiTF.Archive

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    store_dir = Path.join(System.tmp_dir!(), "gitf_archive_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(store_dir)

    GiTF.Test.StoreHelper.stop_store()

    # Delete the ETS cache so the new Archive starts clean
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
    end)

    %{store_dir: store_dir}
  end

  # ── CRUD + timestamps ──────────────────────────────────────────────────

  describe "insert/2" do
    test "assigns a prefix-correct id and timestamps" do
      {:ok, record} = Archive.insert(:missions, %{name: "alpha"})

      assert String.starts_with?(record.id, "msn-")
      assert %DateTime{} = record.inserted_at
      assert %DateTime{} = record.updated_at
      assert record.inserted_at == record.updated_at
    end

    test "preserves a caller-supplied id" do
      {:ok, record} = Archive.insert(:missions, %{id: "msn-custom", name: "beta"})
      assert record.id == "msn-custom"
    end
  end

  describe "get/2 and fetch/2" do
    test "round-trip through insert" do
      {:ok, original} = Archive.insert(:ops, %{status: "pending"})

      assert Archive.get(:ops, original.id) == original
      assert Archive.fetch(:ops, original.id) == {:ok, original}
    end

    test "get returns nil for missing id" do
      assert Archive.get(:ops, "op-nonexistent") == nil
    end

    test "fetch returns {:error, :not_found} for missing id" do
      assert Archive.fetch(:ops, "op-nonexistent") == {:error, :not_found}
    end
  end

  describe "put/2" do
    test "overwrites record, bumps updated_at, preserves inserted_at" do
      {:ok, original} = Archive.insert(:ops, %{status: "pending"})
      Process.sleep(1100)

      modified = Map.put(original, :status, "done")
      {:ok, updated} = Archive.put(:ops, modified)

      assert updated.status == "done"
      assert updated.inserted_at == original.inserted_at
      assert DateTime.compare(updated.updated_at, original.updated_at) in [:gt, :eq]
    end
  end

  # ── update/3 contract ──────────────────────────────────────────────────

  describe "update/3" do
    test "bare map return -> {:ok, updated}" do
      {:ok, rec} = Archive.insert(:ops, %{counter: 0})

      assert {:ok, updated} = Archive.update(:ops, rec.id, fn r ->
        Map.put(r, :counter, r.counter + 1)
      end)

      assert updated.counter == 1
      assert Archive.get(:ops, rec.id).counter == 1
    end

    test "{:ok, record} return -> {:ok, updated}" do
      {:ok, rec} = Archive.insert(:ops, %{counter: 0})

      assert {:ok, updated} = Archive.update(:ops, rec.id, fn r ->
        {:ok, Map.put(r, :counter, 5)}
      end)

      assert updated.counter == 5
    end

    test "{:ok, record, metadata} return -> {:ok, updated, meta}" do
      {:ok, rec} = Archive.insert(:ops, %{status: "a"})

      assert {:ok, updated, meta} = Archive.update(:ops, rec.id, fn r ->
        {:ok, Map.put(r, :status, "b"), %{changed: true}}
      end)

      assert updated.status == "b"
      assert meta == %{changed: true}
    end

    test "{:error, reason} return -> record unchanged" do
      {:ok, rec} = Archive.insert(:ops, %{status: "locked"})

      assert {:error, :cannot_modify} = Archive.update(:ops, rec.id, fn _r ->
        {:error, :cannot_modify}
      end)

      assert Archive.get(:ops, rec.id).status == "locked"
    end

    test "closure raises -> {:error, {:exception, _}}, record unchanged" do
      {:ok, rec} = Archive.insert(:ops, %{status: "ok"})

      assert {:error, {:exception, %RuntimeError{}}} =
               Archive.update(:ops, rec.id, fn _r ->
                 raise "boom"
               end)

      assert Archive.get(:ops, rec.id).status == "ok"
    end

    test "missing id -> {:error, :not_found}" do
      assert {:error, :not_found} = Archive.update(:ops, "op-ghost", fn r -> r end)
    end

    test "non-map return -> {:error, {:bad_update_fn_return, _}}" do
      {:ok, rec} = Archive.insert(:ops, %{status: "ok"})

      assert {:error, {:bad_update_fn_return, :oops}} =
               Archive.update(:ops, rec.id, fn _r -> :oops end)
    end
  end

  # ── delete, all, filter, find_one, count ───────────────────────────────

  describe "delete/2" do
    test "removes the record" do
      {:ok, rec} = Archive.insert(:ops, %{x: 1})
      assert Archive.get(:ops, rec.id) != nil

      :ok = Archive.delete(:ops, rec.id)
      assert Archive.get(:ops, rec.id) == nil
    end
  end

  describe "all/1" do
    test "returns all records in collection" do
      {:ok, _} = Archive.insert(:sectors, %{name: "a"})
      {:ok, _} = Archive.insert(:sectors, %{name: "b"})

      results = Archive.all(:sectors)
      assert length(results) == 2
      names = Enum.map(results, & &1.name) |> Enum.sort()
      assert names == ["a", "b"]
    end

    test "returns empty list for empty collection" do
      assert Archive.all(:sectors) == []
    end
  end

  describe "filter/2" do
    test "returns matching records" do
      {:ok, _} = Archive.insert(:ops, %{status: "done"})
      {:ok, _} = Archive.insert(:ops, %{status: "pending"})
      {:ok, _} = Archive.insert(:ops, %{status: "done"})

      done = Archive.filter(:ops, &(&1.status == "done"))
      assert length(done) == 2
    end
  end

  describe "find_one/2" do
    test "returns first match or nil" do
      {:ok, _} = Archive.insert(:ops, %{status: "pending"})
      {:ok, target} = Archive.insert(:ops, %{status: "special"})

      found = Archive.find_one(:ops, &(&1.status == "special"))
      assert found.id == target.id

      assert Archive.find_one(:ops, &(&1.status == "nope")) == nil
    end
  end

  describe "count/1 and count/2" do
    test "count/1 matches length(all)" do
      {:ok, _} = Archive.insert(:ops, %{x: 1})
      {:ok, _} = Archive.insert(:ops, %{x: 2})

      assert Archive.count(:ops) == 2
      assert Archive.count(:ops) == length(Archive.all(:ops))
    end

    test "count/2 matches length(filter)" do
      {:ok, _} = Archive.insert(:ops, %{status: "a"})
      {:ok, _} = Archive.insert(:ops, %{status: "b"})
      {:ok, _} = Archive.insert(:ops, %{status: "a"})

      pred = &(&1.status == "a")
      assert Archive.count(:ops, pred) == 2
      assert Archive.count(:ops, pred) == length(Archive.filter(:ops, pred))
    end
  end

  # ── update_matching/3 ──────────────────────────────────────────────────

  describe "update_matching/3" do
    test "updates all matching records and returns count" do
      {:ok, _} = Archive.insert(:ops, %{status: "pending", priority: 1})
      {:ok, _} = Archive.insert(:ops, %{status: "pending", priority: 2})
      {:ok, _} = Archive.insert(:ops, %{status: "done", priority: 3})

      count = Archive.update_matching(
        :ops,
        &(&1.status == "pending"),
        &Map.put(&1, :status, "running")
      )

      assert count == 2
      assert Archive.count(:ops, &(&1.status == "running")) == 2
      assert Archive.count(:ops, &(&1.status == "done")) == 1
    end

    test "0 matches returns 0, no write" do
      {:ok, _} = Archive.insert(:ops, %{status: "done"})

      count = Archive.update_matching(
        :ops,
        &(&1.status == "nope"),
        &Map.put(&1, :status, "running")
      )

      assert count == 0
    end
  end

  # ── transact/1 ─────────────────────────────────────────────────────────

  describe "transact/1" do
    test "mutates two collections atomically" do
      {:ok, op} = Archive.insert(:ops, %{status: "pending"})

      :ok = Archive.transact(fn data ->
        # Update op status
        data = put_in(data, [:ops, op.id, :status], "blocked")
        # Insert a dependency in another collection
        dep = %{id: "dep-abc123", op_id: op.id, depends_on: "op-other"}
        deps = Map.get(data, :op_dependencies, %{})
        Map.put(data, :op_dependencies, Map.put(deps, dep.id, dep))
      end)

      assert Archive.get(:ops, op.id).status == "blocked"
      assert Archive.get(:op_dependencies, "dep-abc123").op_id == op.id
    end

    test "changes visible in subsequent reads" do
      :ok = Archive.transact(fn data ->
        Map.put(data, :events, %{"evt-001" => %{id: "evt-001", type: "test"}})
      end)

      assert Archive.get(:events, "evt-001").type == "test"
    end
  end

  # ── Lock serialization ─────────────────────────────────────────────────

  describe "concurrent update/3 serialization" do
    test "50 concurrent increments produce final counter of 50" do
      {:ok, rec} = Archive.insert(:ops, %{counter: 0})

      tasks =
        for _ <- 1..50 do
          Task.async(fn ->
            Archive.update(:ops, rec.id, fn r ->
              Map.put(r, :counter, r.counter + 1)
            end)
          end)
        end

      Task.await_many(tasks, 30_000)

      assert Archive.get(:ops, rec.id).counter == 50
    end
  end

  # ── Backup recovery ────────────────────────────────────────────────────

  describe "backup recovery" do
    test "recovers from corrupted primary via .bak", %{store_dir: store_dir} do
      {:ok, _} = Archive.insert(:missions, %{id: "msn-survive", name: "survivor"})

      # Force a backup by writing the .bak file directly
      data_path = Path.join(store_dir, "section.etf")
      {:ok, good_binary} = File.read(data_path)
      File.write!(data_path <> ".bak", good_binary)

      # Corrupt the primary
      File.write!(data_path, "corrupted-garbage")

      # Restart Archive from same dir — should recover from backup
      GiTF.Test.StoreHelper.stop_store()
      {:ok, _} = Archive.start_link(data_dir: store_dir)

      assert Archive.get(:missions, "msn-survive").name == "survivor"
    end

    test "recovers from .bak.2 when .bak is also corrupted", %{store_dir: store_dir} do
      {:ok, _} = Archive.insert(:missions, %{id: "msn-deep", name: "deep"})

      data_path = Path.join(store_dir, "section.etf")
      {:ok, good_binary} = File.read(data_path)

      # Place good data in .bak.2
      File.write!(data_path <> ".bak.2", good_binary)
      # Corrupt primary and .bak
      File.write!(data_path, "corrupt1")
      File.write!(data_path <> ".bak", "corrupt2")

      GiTF.Test.StoreHelper.stop_store()
      {:ok, _} = Archive.start_link(data_dir: store_dir)

      assert Archive.get(:missions, "msn-deep").name == "deep"
    end

    test "recovers from .bak.3 when .bak and .bak.2 are corrupted", %{store_dir: store_dir} do
      {:ok, _} = Archive.insert(:missions, %{id: "msn-deepest", name: "deepest"})

      data_path = Path.join(store_dir, "section.etf")
      {:ok, good_binary} = File.read(data_path)

      File.write!(data_path <> ".bak.3", good_binary)
      File.write!(data_path, "corrupt1")
      File.write!(data_path <> ".bak", "corrupt2")
      File.write!(data_path <> ".bak.2", "corrupt3")

      GiTF.Test.StoreHelper.stop_store()
      {:ok, _} = Archive.start_link(data_dir: store_dir)

      assert Archive.get(:missions, "msn-deepest").name == "deepest"
    end
  end

  # ── Persistence across restart ─────────────────────────────────────────

  describe "persistence" do
    test "data survives stop and restart from same dir", %{store_dir: store_dir} do
      {:ok, _} = Archive.insert(:ops, %{id: "op-persist", status: "saved"})
      {:ok, _} = Archive.insert(:missions, %{id: "msn-persist", name: "durable"})

      GiTF.Test.StoreHelper.stop_store()

      # Clear ETS so we know data comes from disk
      try do
        :ets.delete(:gitf_store_cache)
      rescue
        ArgumentError -> :ok
      end

      {:ok, _} = Archive.start_link(data_dir: store_dir)

      assert Archive.get(:ops, "op-persist").status == "saved"
      assert Archive.get(:missions, "msn-persist").name == "durable"
    end
  end

  # ── Collection isolation ───────────────────────────────────────────────

  describe "collection isolation" do
    test "writes to :missions do not affect :ops" do
      {:ok, _} = Archive.insert(:missions, %{id: "msn-iso", name: "mission"})
      {:ok, _} = Archive.insert(:ops, %{id: "op-iso", status: "running"})

      assert Archive.get(:ops, "msn-iso") == nil
      assert Archive.get(:missions, "op-iso") == nil
      assert Archive.count(:missions) == 1
      assert Archive.count(:ops) == 1
    end
  end
end
