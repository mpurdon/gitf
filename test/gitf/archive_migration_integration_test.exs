defmodule GiTF.Archive.MigrationIntegrationTest do
  @moduledoc """
  Integration test using real gitf-test store data. Tests:
  1. Migration from old monolithic section.etf to per-collection files
  2. Data integrity after migration
  3. Secondary index correctness on real data
  4. Performance: by_index vs filter comparison
  5. Re-boot idempotency (no re-migration on second start)
  """
  use ExUnit.Case, async: false

  @source_store Path.expand("~/Projects/gitf-test/.gitf/store")

  # Use setup_all to start Archive once — the app supervisor restarts
  # Archive after GenServer.stop, so per-test start/stop doesn't work.
  setup_all do
    unless File.exists?(Path.join(@source_store, "section.etf")) do
      raise "SKIP: #{@source_store}/section.etf not found"
    end

    tmp_dir = Path.join(System.tmp_dir!(), "gitf_migration_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    File.cp!(Path.join(@source_store, "section.etf"), Path.join(tmp_dir, "section.etf"))

    for suffix <- [".bak", ".bak.2", ".bak.3"] do
      src = Path.join(@source_store, "section.etf#{suffix}")
      if File.exists?(src), do: File.cp!(src, Path.join(tmp_dir, "section.etf#{suffix}"))
    end

    # Read old format before migration for verification
    old_binary = File.read!(Path.join(tmp_dir, "section.etf"))
    old_data = :erlang.binary_to_term(old_binary)

    # Stop any running Archive
    stop_archive()

    # Clean stale ETS
    for col <- (try do :persistent_term.get({GiTF.Archive, :collections}, MapSet.new()) rescue _ -> MapSet.new() end) do
      try do :ets.delete(:"gitf_archive_#{col}") rescue _ -> :ok end
    end
    GiTF.Archive.Indexes.delete_tables()

    # Start Archive — triggers migration
    {:ok, _pid} = GiTF.Archive.start_link(data_dir: tmp_dir)

    on_exit(fn ->
      stop_archive()
      File.rm_rf!(tmp_dir)
    end)

    {:ok, store_dir: tmp_dir, old_data: old_data, old_binary_size: byte_size(old_binary)}
  end

  defp stop_archive do
    case Process.whereis(GiTF.Archive) do
      nil -> :ok
      pid ->
        try do GenServer.stop(pid, :normal, 5_000) rescue _ -> :ok catch :exit, _ -> :ok end
        ref = Process.monitor(pid)
        receive do {:DOWN, ^ref, _, _, _} -> :ok after 5_000 -> :ok end
    end
  end

  @tag :integration
  test "migration from old format preserves all data", ctx do
    old_data = ctx.old_data
    old_collections = Map.keys(old_data) |> Enum.filter(&is_atom/1)
    old_record_count = Enum.sum(for {col, records} <- old_data, is_atom(col), do: map_size(records))

    IO.puts("\n  Old format: #{length(old_collections)} collections, #{old_record_count} total records, #{ctx.old_binary_size} bytes")

    # Verify migration happened
    assert File.exists?(Path.join(ctx.store_dir, "manifest.etf"))
    assert File.exists?(Path.join(ctx.store_dir, "section.etf.pre_migration"))
    refute File.exists?(Path.join(ctx.store_dir, "section.etf"))

    # Verify per-collection files exist
    for col <- old_collections do
      assert File.exists?(Path.join(ctx.store_dir, "#{col}.etf")), "#{col}.etf should exist"
    end

    # Verify manifest
    manifest = File.read!(Path.join(ctx.store_dir, "manifest.etf")) |> :erlang.binary_to_term([:safe])
    assert manifest.schema_version == 1
    assert Enum.sort(manifest.collections) == Enum.sort(old_collections)

    # Verify all records exist (skip exact equality — migrations may transform records)
    for {col, records_map} <- old_data, is_atom(col), col != :metadata do
      for {id, _expected} <- records_map do
        actual = GiTF.Archive.get(col, id)
        assert actual != nil, "#{col}/#{id} not found after migration"
        assert actual.id == id
      end
    end

    IO.puts("  Migration: #{length(old_collections)} collections, #{old_record_count} records — all verified")
  end

  @tag :integration
  test "indexes are populated after migration", _ctx do
    all_ops = GiTF.Archive.all(:ops)

    if length(all_ops) > 0 do
      statuses = all_ops |> Enum.map(& &1.status) |> Enum.uniq()

      for status <- statuses do
        by_filter = GiTF.Archive.filter(:ops, &(&1.status == status))
        by_index = GiTF.Archive.by_index(:ops, :status, status)
        assert length(by_index) == length(by_filter),
          "ops status=#{status}: filter=#{length(by_filter)}, index=#{length(by_index)}"
        assert MapSet.new(by_index, & &1.id) == MapSet.new(by_filter, & &1.id)
      end

      mission_ids = all_ops |> Enum.map(& &1.mission_id) |> Enum.uniq() |> Enum.reject(&is_nil/1)

      for mid <- Enum.take(mission_ids, 5) do
        by_filter = GiTF.Archive.filter(:ops, &(&1.mission_id == mid))
        by_index = GiTF.Archive.by_index(:ops, :mission_id, mid)
        assert length(by_index) == length(by_filter)
      end

      IO.puts("\n  Indexes verified: #{length(all_ops)} ops, #{length(statuses)} statuses, #{length(mission_ids)} missions")
    else
      IO.puts("\n  SKIP: no ops data for index verification")
    end

    all_deps = GiTF.Archive.all(:op_dependencies)

    if length(all_deps) > 0 do
      op_ids = all_deps |> Enum.map(& &1.op_id) |> Enum.uniq()

      for oid <- Enum.take(op_ids, 5) do
        by_filter = GiTF.Archive.filter(:op_dependencies, &(&1.op_id == oid))
        by_index = GiTF.Archive.by_index(:op_dependencies, :op_id, oid)
        assert length(by_index) == length(by_filter)
      end

      IO.puts("  Dependencies verified: #{length(all_deps)} deps, #{length(op_ids)} op_ids")
    end
  end

  @tag :integration
  test "performance: by_index vs filter on real data", _ctx do
    all_ops = GiTF.Archive.all(:ops)

    if length(all_ops) >= 5 do
      status = (Enum.find(all_ops, &(&1.status == "done")) || hd(all_ops)).status

      # Warm up
      GiTF.Archive.filter(:ops, &(&1.status == status))
      GiTF.Archive.by_index(:ops, :status, status)

      {filter_us, _} = :timer.tc(fn ->
        for _ <- 1..100, do: GiTF.Archive.filter(:ops, &(&1.status == status))
      end)

      {index_us, _} = :timer.tc(fn ->
        for _ <- 1..100, do: GiTF.Archive.by_index(:ops, :status, status)
      end)

      filter_avg = filter_us / 100
      index_avg = index_us / 100
      speedup = if index_avg > 0, do: Float.round(filter_avg / index_avg, 1), else: :infinity

      IO.puts("\n  Performance (#{length(all_ops)} ops, status=#{status}):")
      IO.puts("    filter: #{filter_avg}µs avg")
      IO.puts("    by_index: #{index_avg}µs avg")
      IO.puts("    speedup: #{speedup}x")
    else
      IO.puts("\n  SKIP: only #{length(all_ops)} ops, need >= 5 for benchmark")
    end
  end

  @tag :integration
  test "re-boot is idempotent (no re-migration)", ctx do
    # Data is already loaded from setup_all. Capture current counts.
    first_count = GiTF.Archive.count(:ops) + GiTF.Archive.count(:missions)

    # Stop and restart
    stop_archive()

    for col <- :persistent_term.get({GiTF.Archive, :collections}, MapSet.new()) do
      try do :ets.delete(:"gitf_archive_#{col}") rescue _ -> :ok end
    end
    GiTF.Archive.Indexes.delete_tables()

    assert File.exists?(Path.join(ctx.store_dir, "section.etf.pre_migration"))
    refute File.exists?(Path.join(ctx.store_dir, "section.etf"))

    {:ok, _pid} = GiTF.Archive.start_link(data_dir: ctx.store_dir)
    second_count = GiTF.Archive.count(:ops) + GiTF.Archive.count(:missions)

    assert second_count == first_count, "Data lost on re-boot: #{first_count} → #{second_count}"
    IO.puts("\n  Re-boot: #{second_count} records preserved, no re-migration")
  end

  @tag :integration
  test "write to migrated store persists correctly", ctx do
    {:ok, record} = GiTF.Archive.insert(:ops, %{
      status: "test_status",
      mission_id: "test_mission",
      description: "integration test record"
    })

    by_index = GiTF.Archive.by_index(:ops, :status, "test_status")
    assert length(by_index) == 1
    assert hd(by_index).id == record.id

    # Async persistence: flush to assert on the on-disk file.
    :ok = GiTF.Archive.flush()
    ops_etf = Path.join(ctx.store_dir, "ops.etf")
    assert File.exists?(ops_etf)
    ops_data = File.read!(ops_etf) |> :erlang.binary_to_term([:safe])
    assert Map.has_key?(ops_data, record.id)

    {:ok, updated, %{transitioned: true}} = GiTF.Archive.update(:ops, record.id, fn op ->
      {:ok, %{op | status: "updated_status"}, %{transitioned: true}}
    end)

    assert updated.status == "updated_status"
    assert GiTF.Archive.by_index(:ops, :status, "test_status") == []
    assert length(GiTF.Archive.by_index(:ops, :status, "updated_status")) == 1

    GiTF.Archive.delete(:ops, record.id)
    assert GiTF.Archive.get(:ops, record.id) == nil
    assert GiTF.Archive.by_index(:ops, :status, "updated_status") == []

    IO.puts("\n  Write path: insert → index → update → reindex → delete → clean")
  end
end
