defmodule GiTF.ArchiveTest do
  @moduledoc """
  Characterization tests for GiTF.Archive.

  Exercises the full CRUD surface, atomic update/3 contract,
  bulk operations, transact/1, lock serialization, backup recovery,
  persistence across restarts, collection isolation, per-collection
  file storage, migration from monolithic format, and per-collection
  corruption recovery.
  """

  use ExUnit.Case, async: false

  alias GiTF.Archive

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    store_dir =
      Path.join(System.tmp_dir!(), "gitf_archive_test_#{:erlang.unique_integer([:positive])}")

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
      GiTF.Test.StoreHelper.restore_app_store()
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

      assert {:ok, updated} =
               Archive.update(:ops, rec.id, fn r ->
                 Map.put(r, :counter, r.counter + 1)
               end)

      assert updated.counter == 1
      assert Archive.get(:ops, rec.id).counter == 1
    end

    test "{:ok, record} return -> {:ok, updated}" do
      {:ok, rec} = Archive.insert(:ops, %{counter: 0})

      assert {:ok, updated} =
               Archive.update(:ops, rec.id, fn r ->
                 {:ok, Map.put(r, :counter, 5)}
               end)

      assert updated.counter == 5
    end

    test "{:ok, record, metadata} return -> {:ok, updated, meta}" do
      {:ok, rec} = Archive.insert(:ops, %{status: "a"})

      assert {:ok, updated, meta} =
               Archive.update(:ops, rec.id, fn r ->
                 {:ok, Map.put(r, :status, "b"), %{changed: true}}
               end)

      assert updated.status == "b"
      assert meta == %{changed: true}
    end

    test "{:error, reason} return -> record unchanged" do
      {:ok, rec} = Archive.insert(:ops, %{status: "locked"})

      assert {:error, :cannot_modify} =
               Archive.update(:ops, rec.id, fn _r ->
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

      count =
        Archive.update_matching(
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

      count =
        Archive.update_matching(
          :ops,
          &(&1.status == "nope"),
          &Map.put(&1, :status, "running")
        )

      assert count == 0
    end
  end

  # ── transact/1 (now a synchronous flush barrier) ───────────────────────

  describe "transact/1 and flush/0" do
    test "writes to multiple collections are visible immediately (ETS-first)" do
      {:ok, op} = Archive.insert(:ops, %{status: "pending"})
      {:ok, _} = Archive.update(:ops, op.id, fn o -> %{o | status: "blocked"} end)
      {:ok, _} = Archive.insert(:op_dependencies, %{id: "dep-abc123", op_id: op.id})

      # Reads are lock-free ETS — no flush needed for in-memory visibility.
      assert Archive.get(:ops, op.id).status == "blocked"
      assert Archive.get(:op_dependencies, "dep-abc123").op_id == op.id
    end

    test "flush/0 persists pending writes to disk", %{store_dir: store_dir} do
      {:ok, _} = Archive.insert(:events, %{id: "evt-001", type: "test"})
      refute File.exists?(Path.join(store_dir, "events.etf")), "persistence should be async"

      assert :ok = Archive.flush()
      assert File.exists?(Path.join(store_dir, "events.etf"))
    end

    test "transact/1 is a flush barrier (backwards-compat)" do
      {:ok, _} = Archive.insert(:events, %{id: "evt-002", type: "t"})
      assert :ok = Archive.transact(fn data -> data end)
      assert Archive.get(:events, "evt-002").type == "t"
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
      :ok = Archive.flush()

      # Force a backup by writing the .bak file for the missions collection
      col_path = Path.join(store_dir, "missions.etf")
      {:ok, good_binary} = File.read(col_path)
      File.write!(col_path <> ".bak", good_binary)

      # Corrupt the primary collection file
      File.write!(col_path, "corrupted-garbage")

      # Restart Archive from same dir — should recover from backup
      GiTF.Test.StoreHelper.stop_store()
      {:ok, _} = Archive.start_link(data_dir: store_dir)

      assert Archive.get(:missions, "msn-survive").name == "survivor"
    end

    test "recovers from .bak.2 when .bak is also corrupted", %{store_dir: store_dir} do
      {:ok, _} = Archive.insert(:missions, %{id: "msn-deep", name: "deep"})
      :ok = Archive.flush()

      col_path = Path.join(store_dir, "missions.etf")
      {:ok, good_binary} = File.read(col_path)

      # Place good data in .bak.2
      File.write!(col_path <> ".bak.2", good_binary)
      # Corrupt primary and .bak
      File.write!(col_path, "corrupt1")
      File.write!(col_path <> ".bak", "corrupt2")

      GiTF.Test.StoreHelper.stop_store()
      {:ok, _} = Archive.start_link(data_dir: store_dir)

      assert Archive.get(:missions, "msn-deep").name == "deep"
    end

    test "recovers from .bak.3 when .bak and .bak.2 are corrupted", %{store_dir: store_dir} do
      {:ok, _} = Archive.insert(:missions, %{id: "msn-deepest", name: "deepest"})
      :ok = Archive.flush()

      col_path = Path.join(store_dir, "missions.etf")
      {:ok, good_binary} = File.read(col_path)

      File.write!(col_path <> ".bak.3", good_binary)
      File.write!(col_path, "corrupt1")
      File.write!(col_path <> ".bak", "corrupt2")
      File.write!(col_path <> ".bak.2", "corrupt3")

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
      # Async persistence: flush explicitly so the restart reads it from disk.
      :ok = Archive.flush()

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

  # ── Migration from monolithic format ───────────────────────────────────

  describe "migration from monolithic section.etf" do
    test "migrates old format to per-collection files", %{store_dir: store_dir} do
      # Stop archive so we can set up the old-format fixture
      GiTF.Test.StoreHelper.stop_store()

      # Remove any per-collection files written by setup
      for f <- File.ls!(store_dir), String.ends_with?(f, ".etf") do
        File.rm!(Path.join(store_dir, f))
      end

      # Create a monolithic section.etf in the old format
      old_data = %{
        missions: %{
          "msn-migr1" => %{
            id: "msn-migr1",
            name: "migrated_mission",
            inserted_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          }
        },
        ops: %{
          "op-migr1" => %{
            id: "op-migr1",
            status: "pending",
            inserted_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          },
          "op-migr2" => %{
            id: "op-migr2",
            status: "done",
            inserted_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          }
        }
      }

      old_path = Path.join(store_dir, "section.etf")
      File.write!(old_path, :erlang.term_to_binary(old_data))

      # Start archive — should detect old format and migrate
      {:ok, _} = Archive.start_link(data_dir: store_dir)

      # Per-collection files should exist
      assert File.exists?(Path.join(store_dir, "missions.etf"))
      assert File.exists?(Path.join(store_dir, "ops.etf"))

      # Manifest should exist
      assert File.exists?(Path.join(store_dir, "manifest.etf"))

      # Old file should be renamed
      assert File.exists?(old_path <> ".pre_migration")
      refute File.exists?(old_path)

      # Data should be queryable
      assert Archive.get(:missions, "msn-migr1").name == "migrated_mission"
      assert Archive.get(:ops, "op-migr1").status == "pending"
      assert Archive.get(:ops, "op-migr2").status == "done"
    end

    test "discovers per-collection files not listed in manifest", %{store_dir: store_dir} do
      # Simulates a corrupted/stale manifest leaving collection files orphaned.
      # Boot must scan the dir and load all *.etf files anyway.
      GiTF.Test.StoreHelper.stop_store()

      for f <- File.ls!(store_dir),
          String.ends_with?(f, ".etf"),
          do: File.rm!(Path.join(store_dir, f))

      # Write per-collection files for sectors and missions
      sector_data = %{
        "sec-1" => %{
          id: "sec-1",
          name: "test-sector",
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      }

      File.write!(Path.join(store_dir, "sectors.etf"), :erlang.term_to_binary(sector_data))

      mission_data = %{
        "msn-1" => %{
          id: "msn-1",
          name: "test-mission",
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      }

      File.write!(Path.join(store_dir, "missions.etf"), :erlang.term_to_binary(mission_data))

      # Write a stale manifest listing only :missions (sectors orphaned)
      manifest = %{schema_version: 1, collections: [:missions], updated_at: DateTime.utc_now()}
      File.write!(Path.join(store_dir, "manifest.etf"), :erlang.term_to_binary(manifest))

      {:ok, _} = Archive.start_link(data_dir: store_dir)

      # Both collections must be loaded despite manifest only listing missions
      assert Archive.get(:sectors, "sec-1").name == "test-sector"
      assert Archive.get(:missions, "msn-1").name == "test-mission"
      assert length(Archive.all(:sectors)) == 1
    end
  end

  # ── Per-collection corruption isolation ────────────────────────────────

  describe "per-collection corruption" do
    test "corrupted collection recovers from backup, others intact", %{store_dir: store_dir} do
      {:ok, _} = Archive.insert(:missions, %{id: "msn-safe", name: "safe"})
      {:ok, _} = Archive.insert(:ops, %{id: "op-safe", status: "running"})
      :ok = Archive.flush()

      # Create a backup for ops collection
      ops_path = Path.join(store_dir, "ops.etf")
      {:ok, good_binary} = File.read(ops_path)
      File.write!(ops_path <> ".bak", good_binary)

      # Corrupt ops collection file only
      File.write!(ops_path, "corrupted-garbage")

      # Restart — missions should be fine, ops should recover from backup
      GiTF.Test.StoreHelper.stop_store()
      {:ok, _} = Archive.start_link(data_dir: store_dir)

      assert Archive.get(:missions, "msn-safe").name == "safe"
      assert Archive.get(:ops, "op-safe").status == "running"
    end
  end

  # ── Multi-table heir survival ──────────────────────────────────────────

  describe "multi-table heir" do
    test "all collection + index tables survive Archive crash and restart", %{
      store_dir: store_dir
    } do
      # Ensure the heir is alive
      heir_pid = GiTF.Archive.TableHeir.pid()
      assert is_pid(heir_pid), "TableHeir must be running"

      # Insert data — this writes to disk via the caller process
      {:ok, op} = Archive.insert(:ops, %{status: "running", mission_id: "msn-x"})
      {:ok, msn} = Archive.insert(:missions, %{name: "important"})

      # Verify index works before crash
      assert [op.id] == GiTF.Archive.Indexes.lookup(:ops, :status, "running")

      # Async persistence: flush so the restart below recovers from disk.
      :ok = Archive.flush()

      # Stop and restart Archive so init_store creates tables owned by Archive
      # (tables created via ensure_table in insert are owned by the test process)
      GiTF.Test.StoreHelper.stop_store()

      # Clean up ETS tables from the test process
      for tab <- [:gitf_archive_ops, :gitf_archive_missions] do
        if :ets.info(tab) != :undefined, do: :ets.delete(tab)
      end

      GiTF.Archive.Indexes.delete_tables()
      {:ok, _} = Archive.start_link(data_dir: store_dir)

      # Verify data survived the restart
      assert Archive.get(:ops, op.id).status == "running"
      assert Archive.get(:missions, msn.id).name == "important"

      # Now tables are owned by the Archive GenServer — verify heir is set
      assert :ets.info(:gitf_archive_ops, :heir) == heir_pid
      assert :ets.info(:gitf_archive_missions, :heir) == heir_pid

      # Kill the Archive process (simulates crash)
      archive_pid = Process.whereis(GiTF.Archive)
      assert is_pid(archive_pid)
      Process.unlink(archive_pid)
      ref = Process.monitor(archive_pid)
      Process.exit(archive_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^archive_pid, _reason}, 1000

      # Brief pause for ETS-TRANSFER messages to be processed
      Process.sleep(50)

      # Tables should still exist — held by the heir
      assert :ets.info(:gitf_archive_ops) != :undefined
      assert :ets.info(:gitf_archive_missions) != :undefined

      # Index tables should also survive
      idx_tab = GiTF.Archive.Indexes.index_table(:ops, :status)
      assert :ets.info(idx_tab) != :undefined

      # Restart Archive — it should reclaim tables from heir
      {:ok, _} = Archive.start_link(data_dir: store_dir)

      # Data accessible after restart
      assert Archive.get(:ops, op.id).status == "running"
      assert Archive.get(:missions, msn.id).name == "important"

      # Indexes work after restart
      assert GiTF.Archive.Indexes.lookup(:ops, :status, "running") != []
    end
  end

  # ── New format persistence ─────────────────────────────────────────────

  describe "per-collection file persistence" do
    test "per-collection files exist on disk after insert + flush", %{store_dir: store_dir} do
      {:ok, _} = Archive.insert(:missions, %{id: "msn-disk", name: "on_disk"})
      {:ok, _} = Archive.insert(:ops, %{id: "op-disk", status: "saved"})
      # Persistence is asynchronous; force it for a deterministic disk check.
      :ok = Archive.flush()

      assert File.exists?(Path.join(store_dir, "missions.etf"))
      assert File.exists?(Path.join(store_dir, "ops.etf"))
      assert File.exists?(Path.join(store_dir, "manifest.etf"))

      # Verify the content of each collection file is correct
      {:ok, missions_bin} = File.read(Path.join(store_dir, "missions.etf"))
      missions_data = :erlang.binary_to_term(missions_bin)
      assert Map.has_key?(missions_data, "msn-disk")
      assert missions_data["msn-disk"].name == "on_disk"
    end
  end

  describe "reads do not materialise the collection" do
    # The regression these guard: filter/3 and find_one/2 used to be
    # `all/1 |> Enum.filter/2`, so a predicate matching one record still
    # copied every record in the collection into the caller's heap. With
    # ~200 call sites, several on 30-second patrol timers, that is what took
    # an idle factory's BEAM from 89MB of process memory at boot to 1.3GB.
    #
    # Payloads are integer lists, not binaries: binaries over 64 bytes are
    # reference-counted off-heap, so a binary payload would not show up in
    # the process heap measurement at all.
    @records 2_000
    @payload_len 200

    defp seed_wide_collection do
      for i <- 1..@records do
        {:ok, _} =
          Archive.insert(:ops, %{
            id: "op-wide-#{i}",
            status: if(i == 1, do: "needle", else: "haystack"),
            payload: Enum.to_list(1..@payload_len)
          })
      end
    end

    defp heap_growth_during(fun) do
      :erlang.garbage_collect(self())
      {:memory, before} = Process.info(self(), :memory)
      result = fun.()
      {:memory, after_} = Process.info(self(), :memory)
      {after_ - before, result}
    end

    test "filter/2 keeps only matches on the heap" do
      seed_wide_collection()

      {growth, matches} =
        heap_growth_during(fn ->
          Archive.filter(:ops, &(&1.status == "needle"))
        end)

      assert length(matches) == 1

      # The collection is several MB of on-heap terms. Holding it all live —
      # what the old implementation did — cannot fit in 1MB of growth.
      assert growth < 1_000_000,
             "filter grew the caller's heap by #{growth} bytes; it should keep only matches"
    end

    test "find_one/2 stops at the first match" do
      seed_wide_collection()

      {growth, found} =
        heap_growth_during(fn ->
          Archive.find_one(:ops, &(&1.status == "needle"))
        end)

      assert found.id == "op-wide-1"

      assert growth < 1_000_000,
             "find_one grew the caller's heap by #{growth} bytes; it should stop at the match"
    end

    test "all/1 still returns every record" do
      seed_wide_collection()

      assert length(Archive.all(:ops)) == @records
    end

    test "filter/2 returns every match, not just the first" do
      seed_wide_collection()

      assert length(Archive.filter(:ops, &(&1.status == "haystack"))) == @records - 1
    end

    test "find_one/2 returns nil when nothing matches" do
      seed_wide_collection()

      assert Archive.find_one(:ops, &(&1.status == "absent")) == nil
    end

    test "a predicate that raises is not swallowed by the fold's rescue" do
      # fold/3 rescues ArgumentError for a missing table. A caller's own
      # ArgumentError must still surface rather than looking like an empty
      # collection.
      seed_wide_collection()

      assert_raise ArgumentError, fn ->
        Archive.filter(:ops, fn _ -> raise ArgumentError, "from the predicate" end)
      end
    end
  end
end
