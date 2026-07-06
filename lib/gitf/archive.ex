defmodule GiTF.Archive do
  @moduledoc """
  In-memory-first key-value store backed by per-collection ETF files.

  ETS is the source of truth; each collection is an ETS table plus a
  `<data_dir>/<collection>.etf` file that is a lazily-flushed durable copy.

  Concurrency model (the interesting part):

    * **Reads are lock-free** — `get`/`all`/`filter`/`by_index` hit `:public,
      read_concurrency` ETS directly from the caller.
    * **`insert` is lock-free** — a fresh unique id can never race an existing
      key, so inserts (the hot cost/event/op-creation paths) run concurrently
      straight against ETS.
    * **`put`/`update`/`delete`/`update_matching` serialize *per collection*
      via `GiTF.Archive.Writer` under a `PartitionSupervisor`** — same
      collection → same partition (atomic read-modify-write + index diffs),
      different collections → parallel. Each mutation is a few microsecond ETS
      ops with **no disk I/O** in the critical section.
    * **Persistence is asynchronous** — writers mark a collection dirty in a
      lock-free ETS set; a debounced persister flushes dirty collections to
      disk (atomic tmp+rename) off the write path. `flush/0` forces a
      synchronous flush; the store also flushes on graceful shutdown. The ETS
      heir keeps data alive across an Archive process restart.

  This replaces the previous design (a single global `mkdir` lock held across a
  full-store read + synchronous disk write on *every* mutation), which
  serialized all writes and made each write O(total store size).
  """

  use GenServer
  require Logger

  alias GiTF.Archive.Indexes

  @name __MODULE__
  @indexes_enabled true
  @backup_interval_seconds 300
  @backup_generations 3

  # Lock-free set of collections with un-persisted changes.
  @dirty_table :gitf_archive_dirty

  # Debounce window for the async disk flush. Short enough to bound crash-loss,
  # long enough to batch bursts of writes into one disk write per collection.
  @flush_interval_ms 1_000

  # PartitionSupervisor name for the per-collection write serializers.
  @writers GiTF.Archive.Writers

  # -- Client API ------------------------------------------------------------

  @doc "Starts the store, creating the data directory at `data_dir`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Inserts a record into a collection. Generates an `:id` if missing."
  @spec insert(atom(), map()) :: {:ok, map()}
  def insert(collection, record) do
    record = ensure_id(collection, record)
    record = ensure_timestamps(record)

    # Lock-free: a freshly-generated unique id cannot collide with an existing
    # key, so the insert + index add + dirty-mark run directly against ETS from
    # the caller with no serialization. This is the hot path (costs/events/ops).
    ensure_table(collection)
    :ets.insert(table_name(collection), {record.id, record})
    Indexes.on_put(collection, nil, record)
    mark_dirty(collection)

    {:ok, record}
  end

  @doc "Gets a record by ID. Returns the record or nil."
  @spec get(atom(), String.t()) :: map() | nil
  def get(collection, id) do
    case :ets.lookup(table_name(collection), id) do
      [{^id, record}] -> record
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Fetches a record by ID. Returns `{:ok, record}` or `{:error, :not_found}`."
  @spec fetch(atom(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def fetch(collection, id) do
    case get(collection, id) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @doc "Overwrites a record in the collection."
  @spec put(atom(), map()) :: {:ok, map()}
  def put(collection, record) do
    record = ensure_updated_at(record)
    route_write(collection, {:put, collection, record})
  end

  @doc """
  Atomically updates a record by reading, applying `update_fn`, and writing
  under the file lock. Prevents read-modify-write races where two processes
  read the same record, modify it independently, and the last write wins.

  The `update_fn` receives the current record and may return any of:

    * `record` — the updated record (plain form)
    * `{:ok, record}` — tagged success
    * `{:ok, record, metadata}` — success with caller metadata (returned
       as `{:ok, record, metadata}` to the caller — useful for surfacing
       transition info such as whether a status actually changed)
    * `{:error, reason}` — reject the write and return `{:error, reason}`
       to the caller; the record is NOT modified on disk

  Returns `{:ok, updated_record}`, `{:ok, updated_record, metadata}`,
  `{:error, :not_found}`, `{:error, reason}` (from closure), or
  `{:error, {:exception, error}}` if the closure raised (stacktrace logged).

  ## Example

      Archive.update(:ops, op_id, fn op ->
        Map.merge(op, %{branch: "ghost/abc", files_changed: 3})
      end)

      # Validation / tagged return:
      Archive.update(:ops, op_id, fn op ->
        case validate(op) do
          :ok -> {:ok, %{op | status: "done"}}
          {:error, r} -> {:error, r}
        end
      end)
  """
  @spec update(atom(), String.t(), (map() -> any())) ::
          {:ok, map()} | {:ok, map(), map()} | {:error, term()}
  def update(collection, id, update_fn) when is_function(update_fn, 1) do
    route_write(collection, {:update, collection, id, update_fn})
  end

  @doc "Deletes a record by collection and ID."
  @spec delete(atom(), String.t()) :: :ok
  def delete(collection, id) do
    route_write(collection, {:delete, collection, id})
  end

  @doc "Returns all records in a collection."
  @spec all(atom()) :: [map()]
  def all(collection) do
    :ets.tab2list(table_name(collection)) |> Enum.map(&elem(&1, 1))
  rescue
    ArgumentError -> []
  end

  @doc "Returns records matching a filter function."
  @spec filter(atom(), (map() -> boolean())) :: [map()]
  def filter(collection, fun) do
    all(collection) |> Enum.filter(fun)
  end

  @doc "Returns the first record matching a filter function, or nil."
  @spec find_one(atom(), (map() -> boolean())) :: map() | nil
  def find_one(collection, fun) do
    all(collection) |> Enum.find(fun)
  end

  @doc "Counts records in a collection. O(1) — ETS tracks table size."
  @spec count(atom()) :: non_neg_integer()
  def count(collection) do
    case :ets.info(table_name(collection), :size) do
      size when is_integer(size) -> size
      _ -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc "Counts records matching a filter function."
  @spec count(atom(), (map() -> boolean())) :: non_neg_integer()
  def count(collection, fun) do
    filter(collection, fun) |> length()
  end

  @doc "Returns records matching a secondary index value. O(k) instead of O(n)."
  @spec by_index(atom(), atom(), term()) :: [map()]
  def by_index(collection, field, value) do
    if @indexes_enabled do
      ids = Indexes.lookup(collection, field, value)
      tab = table_name(collection)

      for id <- ids,
          [{^id, record}] <- [:ets.lookup(tab, id)],
          do: record
    else
      filter(collection, &(Map.get(&1, field) == value))
    end
  rescue
    ArgumentError -> []
  end

  @doc "Counts records matching a secondary index value."
  @spec count_by_index(atom(), atom(), term()) :: non_neg_integer()
  def count_by_index(collection, field, value) do
    if @indexes_enabled do
      Indexes.count(collection, field, value)
    else
      count(collection, &(Map.get(&1, field) == value))
    end
  end

  @doc """
  Forces a synchronous flush of all pending (dirty) collections to disk.

  Historically this was `transact(fn data -> data end)` — a no-op mutation used
  only as a flush barrier before shutdown/exfil. With asynchronous persistence
  it is now an explicit synchronous flush. The `fun` argument is accepted for
  backwards compatibility and ignored (there are no multi-collection
  transactions in the codebase).
  """
  @spec transact((map() -> map())) :: :ok
  def transact(_fun \\ nil) do
    flush()
  end

  @doc "Synchronously flush all dirty collections to disk. Returns `:ok`."
  @spec flush() :: :ok
  def flush do
    GenServer.call(@name, :flush, 30_000)
  catch
    :exit, _ -> :ok
  end

  @doc "Updates all matching records with an update function. Returns count updated."
  @spec update_matching(atom(), (map() -> boolean()), (map() -> map())) :: non_neg_integer()
  def update_matching(collection, filter_fun, update_fun) do
    route_write(collection, {:update_matching, collection, filter_fun, update_fun})
  end

  # -- Write routing + low-level mutation (applied by Archive.Writer) --------

  # Route a mutation to the per-collection writer partition. Same collection →
  # same partition → serialized (atomic RMW + index diff); different
  # collections → parallel.
  defp route_write(collection, op) do
    GenServer.call({:via, PartitionSupervisor, {@writers, collection}}, {:apply, op})
  catch
    # If the writer pool isn't up yet (very early boot / tests without the
    # supervisor), apply inline — correctness holds, we just lose the
    # cross-process serialization until the pool exists.
    :exit, _ -> apply_write(op)
  end

  @doc false
  # Applies a single mutation against ETS + indexes + the dirty set. Called by
  # `GiTF.Archive.Writer` (serialized per collection). NOT part of the public
  # API — use insert/put/update/delete/update_matching.
  def apply_write({:put, collection, record}) do
    ensure_table(collection)
    old = get(collection, record.id)
    :ets.insert(table_name(collection), {record.id, record})
    Indexes.on_put(collection, old, record)
    mark_dirty(collection)
    {:ok, record}
  end

  def apply_write({:update, collection, id, update_fn}) do
    case get(collection, id) do
      nil ->
        {:error, :not_found}

      record ->
        try do
          case update_fn.(record) do
            {:error, reason} -> {:error, reason}
            {:ok, updated, meta} when is_map(updated) -> commit_update(collection, record, updated, {:meta, meta})
            {:ok, updated} when is_map(updated) -> commit_update(collection, record, updated, nil)
            updated when is_map(updated) -> commit_update(collection, record, updated, nil)
            other -> {:error, {:bad_update_fn_return, other}}
          end
        rescue
          e ->
            Logger.error(
              "Archive.update closure for #{inspect(collection)}/#{id} raised: " <>
                Exception.format(:error, e, __STACKTRACE__)
            )

            {:error, {:exception, e}}
        end
    end
  end

  def apply_write({:delete, collection, id}) do
    case get(collection, id) do
      nil ->
        :ok

      old ->
        :ets.delete(table_name(collection), id)
        Indexes.on_delete(collection, old)
        mark_dirty(collection)
        :ok
    end
  end

  def apply_write({:update_matching, collection, filter_fun, update_fun}) do
    matching = collection |> all() |> Enum.filter(filter_fun)

    for old <- matching do
      updated = update_fun.(old) |> ensure_updated_at()
      :ets.insert(table_name(collection), {updated.id, updated})
      Indexes.on_put(collection, old, updated)
    end

    if matching != [], do: mark_dirty(collection)
    length(matching)
  end

  # Writes `updated`, diffs the index against `old`, marks dirty, returns the
  # caller-facing result (defaulting to `{:ok, updated}`).
  defp commit_update(collection, old, updated_raw, meta_tag) do
    updated = ensure_updated_at(updated_raw)
    :ets.insert(table_name(collection), {updated.id, updated})
    Indexes.on_put(collection, old, updated)
    mark_dirty(collection)

    case meta_tag do
      {:meta, meta} -> {:ok, updated, meta}
      nil -> {:ok, updated}
    end
  end

  # Mark a collection as having un-persisted changes (lock-free).
  defp mark_dirty(collection) do
    :ets.insert(@dirty_table, {collection})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # -- GenServer callbacks ---------------------------------------------------

  @impl true
  def init(opts) do
    # Flush any un-persisted writes on graceful shutdown (SIGTERM / app stop).
    Process.flag(:trap_exit, true)

    data_dir = Keyword.fetch!(opts, :data_dir)
    File.mkdir_p!(data_dir)

    # Legacy path kept for migration detection
    data_path = Path.join(data_dir, "section.etf")

    # Archive paths in persistent_term so API functions can access them
    # without going through the GenServer process
    :persistent_term.put({__MODULE__, :data_path}, data_path)
    :persistent_term.put({__MODULE__, :data_dir}, data_dir)

    # Lock-free dirty set: collections with writes not yet flushed to disk.
    ensure_dirty_table()

    # Create per-collection ETS tables from disk data
    init_store()

    # Run migrations after store is initialized
    GiTF.Migrations.migrate!()

    schedule_flush()

    {:ok, %{data_dir: data_dir, data_path: data_path}}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    flush_dirty()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:flush, state) do
    flush_dirty()
    schedule_flush()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    # Best-effort final flush so a graceful stop doesn't drop the debounce
    # window's worth of writes. Skipped when the periodic flush is disabled
    # (tests) so stopping the store can't write into a temp dir a test is
    # concurrently tearing down — those tests flush explicitly instead.
    if async_flush_enabled?(), do: flush_dirty()
    :ok
  rescue
    _ -> :ok
  end

  defp async_flush_enabled? do
    case Application.get_env(:gitf, :archive_flush_interval_ms, @flush_interval_ms) do
      ms when is_integer(ms) and ms > 0 -> true
      _ -> false
    end
  end

  defp schedule_flush do
    # Interval is configurable; <= 0 disables the periodic timer (used in tests,
    # which flush explicitly + rely on the terminate flush) so a background disk
    # write can't race a test's temp-dir teardown.
    if async_flush_enabled?() do
      Process.send_after(
        self(),
        :flush,
        Application.get_env(:gitf, :archive_flush_interval_ms, @flush_interval_ms)
      )
    end
  end

  defp ensure_dirty_table do
    case :ets.info(@dirty_table) do
      :undefined -> :ets.new(@dirty_table, [:named_table, :public, :set, write_concurrency: true])
      _ -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  # Persist every collection currently marked dirty. Clear each dirty mark
  # BEFORE serializing its ETS: a write landing during serialization re-marks
  # the collection (writers mark dirty AFTER the ETS op), so it is captured on
  # the next flush — no lost write, no lock held across disk I/O.
  defp flush_dirty do
    dirty = :ets.tab2list(@dirty_table) |> Enum.map(&elem(&1, 0))

    for col <- dirty do
      :ets.delete(@dirty_table, col)
      persist_collection(col)
    end

    if dirty != [], do: maybe_update_manifest()
    :ok
  rescue
    e ->
      Logger.warning("Archive flush_dirty failed: #{Exception.message(e)}")
      :ok
  end

  defp persist_collection(col) do
    binary = :ets.tab2list(table_name(col)) |> Map.new() |> :erlang.term_to_binary()
    path = collection_path(col)
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, binary),
         :ok <- File.rename(tmp, path) do
      maybe_backup_collection(col, binary)
    else
      {:error, reason} ->
        Logger.error("Archive write failed for #{col}: #{inspect(reason)}")
        # Re-mark dirty so the next flush retries rather than silently dropping.
        mark_dirty(col)

        GiTF.Telemetry.emit([:gitf, :store, :write_error], %{}, %{
          collection: col,
          reason: reason,
          cache_disk_divergent: true
        })
    end
  rescue
    e ->
      Logger.error("Archive persist_collection #{col} raised: #{Exception.message(e)}")
      mark_dirty(col)
      :ok
  end

  # -- Path helpers -----------------------------------------------------------

  defp data_path, do: :persistent_term.get({__MODULE__, :data_path})
  defp data_dir, do: :persistent_term.get({__MODULE__, :data_dir})
  defp collection_path(col), do: Path.join(data_dir(), "#{col}.etf")
  defp manifest_path, do: Path.join(data_dir(), "manifest.etf")

  # -- File I/O (lock-free reads; async persistence — see flush_dirty/0) -----

  # Reads old monolithic section.etf — used only for migration
  defp read_data_from_disk do
    case File.read(data_path()) do
      {:ok, binary} ->
        deserialize(binary)

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.error("Archive read failed: #{inspect(reason)}, trying backup")
        recover_from_backup()
    end
  end

  defp deserialize(binary) do
    try do
      :erlang.binary_to_term(binary, [:safe])
    rescue
      ArgumentError ->
        try do
          # Existing data may contain atoms not yet loaded — fall back to unsafe
          :erlang.binary_to_term(binary)
        rescue
          _ -> nil
        end
    catch
      _, _ -> nil
    end
  end

  defp read_collection_from_disk(col) do
    path = collection_path(col)

    case File.read(path) do
      {:ok, binary} ->
        case deserialize(binary) do
          nil -> recover_collection_from_backup(col)
          data -> data
        end

      {:error, :enoent} ->
        %{}

      {:error, _reason} ->
        recover_collection_from_backup(col)
    end
  end

  # Legacy monolithic backup recovery (for migration path only)
  defp recover_from_backup do
    # Try each backup generation in order: .bak, .bak.2, .bak.3
    backup_paths =
      [data_path() <> ".bak"] ++
        Enum.map(2..@backup_generations, fn gen -> data_path() <> ".bak.#{gen}" end)

    Enum.reduce_while(backup_paths, %{}, fn backup, _acc ->
      case File.read(backup) do
        {:ok, binary} ->
          try do
            data = :erlang.binary_to_term(binary)
            Logger.warning("Archive corrupted — recovered from #{Path.basename(backup)}")
            # Atomic rewrite via temp+rename so a crash mid-recovery doesn't
            # leave the primary file half-written.
            recovery_tmp = data_path() <> ".tmp"
            with :ok <- File.write(recovery_tmp, binary),
                 :ok <- File.rename(recovery_tmp, data_path()) do
              :ok
            else
              _ -> :ok
            end
            {:halt, data}
          rescue
            _ ->
              Logger.warning("Backup #{Path.basename(backup)} also corrupted, trying next")
              {:cont, %{}}
          end

        {:error, _} ->
          {:cont, %{}}
      end
    end)
    |> case do
      data when data == %{} ->
        Logger.error("All backups exhausted, starting with empty store")
        GiTF.Telemetry.emit([:gitf, :store, :data_loss], %{}, %{reason: "all_backups_exhausted"})

        try do
          Phoenix.PubSub.broadcast(
            GiTF.PubSub,
            "section:alerts",
            {:store_data_loss, "all_backups_exhausted"}
          )
        rescue
          e ->
            Logger.warning("Archive data-loss PubSub broadcast failed: #{Exception.message(e)}")
            :ok
        end

        %{}

      data ->
        data
    end
  end

  # -- Per-collection backups ------------------------------------------------

  defp maybe_backup_collection(col, binary) do
    backup_path = collection_path(col) <> ".bak"

    should_backup =
      case File.stat(backup_path) do
        {:ok, %{mtime: mtime}} ->
          mtime_seconds =
            :calendar.datetime_to_gregorian_seconds(mtime) -
              :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})

          System.os_time(:second) - mtime_seconds > @backup_interval_seconds

        {:error, _} ->
          true
      end

    if should_backup do
      rotate_collection_backups(col)
      backup_tmp = backup_path <> ".tmp"

      with :ok <- File.write(backup_tmp, binary),
           :ok <- File.rename(backup_tmp, backup_path) do
        :ok
      else
        {:error, reason} ->
          Logger.warning("Archive backup write failed for #{col}: #{inspect(reason)}")
          File.rm(backup_tmp)
          :ok
      end
    end
  rescue
    e ->
      Logger.warning("Archive maybe_backup_collection failed for #{col}: #{Exception.message(e)}")
      :ok
  end

  defp rotate_collection_backups(col) do
    base = collection_path(col)

    (@backup_generations - 1)..1//-1
    |> Enum.each(fn gen ->
      src = if gen == 1, do: base <> ".bak", else: base <> ".bak.#{gen}"
      dst = base <> ".bak.#{gen + 1}"
      if File.exists?(src), do: File.rename(src, dst)
    end)
  rescue
    e ->
      Logger.warning("Archive rotate_collection_backups failed for #{col}: #{Exception.message(e)}")
      :ok
  end

  defp recover_collection_from_backup(col) do
    base = collection_path(col)

    backup_paths =
      [base <> ".bak"] ++
        Enum.map(2..@backup_generations, fn gen -> base <> ".bak.#{gen}" end)

    Enum.reduce_while(backup_paths, %{}, fn backup, _acc ->
      case File.read(backup) do
        {:ok, binary} ->
          case deserialize(binary) do
            nil ->
              Logger.warning("Backup #{Path.basename(backup)} for #{col} corrupted, trying next")
              {:cont, %{}}

            data ->
              Logger.warning("Archive #{col} corrupted — recovered from #{Path.basename(backup)}")
              # Restore the primary file
              tmp = base <> ".tmp"
              with :ok <- File.write(tmp, binary),
                   :ok <- File.rename(tmp, base) do
                :ok
              else
                _ -> :ok
              end
              {:halt, data}
          end

        {:error, _} ->
          {:cont, %{}}
      end
    end)
    |> case do
      data when data == %{} ->
        Logger.error("All backups for #{col} exhausted, starting empty")

        GiTF.Telemetry.emit([:gitf, :store, :data_loss], %{}, %{
          reason: "all_backups_exhausted",
          collection: col
        })

        %{}

      data ->
        data
    end
  end

  # -- Manifest management ---------------------------------------------------

  defp maybe_update_manifest do
    current = known_collections() |> MapSet.to_list() |> Enum.sort()
    manifest = read_manifest()

    if manifest == nil or manifest.collections != current do
      write_manifest(%{schema_version: 1, collections: current, updated_at: DateTime.utc_now()})
    end
  end

  defp read_manifest do
    case File.read(manifest_path()) do
      {:ok, binary} ->
        try do
          :erlang.binary_to_term(binary, [:safe])
        rescue
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp write_manifest(manifest) do
    binary = :erlang.term_to_binary(manifest)
    tmp = manifest_path() <> ".tmp"
    File.write!(tmp, binary)
    File.rename!(tmp, manifest_path())
  end

  # -- Per-collection ETS tables ------------------------------------------------

  defp table_name(col), do: :"gitf_archive_#{col}"

  defp known_collections, do: :persistent_term.get({__MODULE__, :collections}, MapSet.new())

  defp register_collection(col) do
    cols = known_collections()
    unless MapSet.member?(cols, col), do: :persistent_term.put({__MODULE__, :collections}, MapSet.put(cols, col))
  end

  defp clear_collection_registry do
    :persistent_term.put({__MODULE__, :collections}, MapSet.new())
  end

  defp init_store do
    heir_pid = GiTF.Archive.TableHeir.pid()

    # Clean up stale tables from a previous instance
    for old_col <- known_collections() do
      old_tab = table_name(old_col)
      case :ets.info(old_tab) do
        :undefined -> :ok
        _ ->
          if is_pid(heir_pid), do: GiTF.Archive.TableHeir.claim(old_tab)
          :ets.delete(old_tab)
      end
    end

    clear_collection_registry()

    data = load_or_migrate()

    # Initialize index tables before populating data
    Indexes.delete_tables()
    Indexes.init_tables()

    for {col, records} <- data, is_atom(col) do
      tab = table_name(col)

      case :ets.info(tab) do
        :undefined ->
          opts = [:named_table, :public, :set, read_concurrency: true]
          opts = if is_pid(heir_pid), do: opts ++ [{:heir, heir_pid, :transfer}], else: opts
          :ets.new(tab, opts)
          if is_pid(heir_pid), do: GiTF.Archive.TableHeir.register(tab)

        _ ->
          if is_pid(heir_pid), do: GiTF.Archive.TableHeir.claim(tab)
          :ets.delete_all_objects(tab)
      end

      for {id, record} <- records do
        :ets.insert(tab, {id, record})
        Indexes.on_put(col, nil, record)
      end

      register_collection(col)
    end
  rescue
    ArgumentError -> :ok
  end

  # Decides which load path to use: new per-collection, migration, or fresh.
  defp load_or_migrate do
    cond do
      File.exists?(manifest_path()) ->
        load_from_per_collection_files()

      File.exists?(data_path()) ->
        migrate_from_monolithic()

      true ->
        %{}
    end
  end

  defp load_from_per_collection_files do
    # Union of (a) collections declared in the manifest and (b) collections
    # discovered by scanning the data directory for *.etf files. The
    # discovery path defends against an incomplete/stale manifest leaving
    # collection files orphaned on disk.
    manifest_collections =
      case read_manifest() do
        %{collections: cols} when is_list(cols) -> cols
        _ -> []
      end

    discovered_collections = scan_collection_files()

    collections =
      MapSet.union(MapSet.new(manifest_collections), MapSet.new(discovered_collections))
      |> MapSet.to_list()

    if discovered_collections != [] and
         MapSet.size(MapSet.difference(MapSet.new(discovered_collections), MapSet.new(manifest_collections))) > 0 do
      missing = MapSet.difference(MapSet.new(discovered_collections), MapSet.new(manifest_collections))
      Logger.warning(
        "Archive: discovered #{MapSet.size(missing)} collections on disk not in manifest: " <>
          inspect(MapSet.to_list(missing)) <>
          " — manifest will be repaired on next write"
      )
    end

    for col <- collections, into: %{} do
      {col, read_collection_from_disk(col)}
    end
  end

  # Returns list of collection atoms found by scanning the data directory
  # for *.etf files. Excludes manifest, section.etf, *.bak/*.tmp/.pre_migration.
  defp scan_collection_files do
    case File.ls(data_dir()) do
      {:ok, files} ->
        for file <- files,
            String.ends_with?(file, ".etf"),
            not String.contains?(file, ".bak"),
            not String.contains?(file, ".tmp"),
            not String.contains?(file, ".pre_migration"),
            file != "manifest.etf",
            file != "section.etf",
            {:ok, col} <- [safe_collection_atom(file)],
            do: col

      {:error, _} ->
        []
    end
  end

  # A collection name comes from a filename on disk — bound atom creation.
  defp safe_collection_atom(file) do
    file |> String.replace_suffix(".etf", "") |> GiTF.SafeAtom.intern()
  end

  defp migrate_from_monolithic do
    Logger.info("Archive: migrating from monolithic section.etf to per-collection files")
    data = read_data_from_disk()

    # Write each collection to its own file
    for {col, records} <- data, is_atom(col) do
      binary = :erlang.term_to_binary(records)
      path = collection_path(col)
      tmp = path <> ".tmp"

      with :ok <- File.write(tmp, binary),
           :ok <- File.rename(tmp, path) do
        :ok
      else
        {:error, reason} ->
          Logger.error("Archive migration write failed for #{col}: #{inspect(reason)}")
      end
    end

    # Write manifest
    collections = data |> Map.keys() |> Enum.filter(&is_atom/1) |> Enum.sort()
    write_manifest(%{schema_version: 1, collections: collections, updated_at: DateTime.utc_now()})

    # Preserve old file
    File.rename(data_path(), data_path() <> ".pre_migration")

    GiTF.Telemetry.emit([:gitf, :store, :migrated_v1], %{collection_count: length(collections)}, %{
      collections: collections
    })

    Logger.info("Archive: migration complete — #{length(collections)} collections")

    data
  end

  defp ensure_table(col) do
    tab = table_name(col)

    case :ets.info(tab) do
      :undefined ->
        heir_pid = GiTF.Archive.TableHeir.pid()
        opts = [:named_table, :public, :set, read_concurrency: true]
        opts = if is_pid(heir_pid), do: opts ++ [{:heir, heir_pid, :transfer}], else: opts
        :ets.new(tab, opts)
        if is_pid(heir_pid), do: GiTF.Archive.TableHeir.register(tab)
        register_collection(col)

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end


  # -- Private helpers -------------------------------------------------------

  defp ensure_id(_collection, %{id: id} = record) when is_binary(id) and id != "" do
    record
  end

  defp ensure_id(collection, record) do
    prefix = collection_prefix(collection)
    Map.put(record, :id, GiTF.ID.generate(prefix))
  end

  defp collection_prefix(:sectors), do: :sec
  defp collection_prefix(:ghosts), do: :ghost
  defp collection_prefix(:ops), do: :op
  defp collection_prefix(:missions), do: :msn
  defp collection_prefix(:links), do: :lnk
  defp collection_prefix(:costs), do: :cst
  defp collection_prefix(:shells), do: :cel
  defp collection_prefix(:op_dependencies), do: :dep
  defp collection_prefix(:mission_phase_transitions), do: :mpt
  defp collection_prefix(:sector_research_cache), do: :src
  defp collection_prefix(:research_file_index), do: :rfi
  defp collection_prefix(:audit_results), do: :vrf
  defp collection_prefix(:context_snapshots), do: :ctx
  defp collection_prefix(:model_reputation), do: :mrp
  defp collection_prefix(:approval_requests), do: :apr
  defp collection_prefix(:debriefs), do: :prv
  defp collection_prefix(:backups), do: :ckp
  defp collection_prefix(:model_scores), do: :msc
  defp collection_prefix(:events), do: :evt
  defp collection_prefix(:agent_identities), do: :agi
  defp collection_prefix(:runs), do: :run
  defp collection_prefix(:skills), do: :skill
  defp collection_prefix(:mission_outcomes), do: :out
  defp collection_prefix(_), do: :gtf

  defp ensure_timestamps(record) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    record
    |> Map.put_new(:inserted_at, now)
    |> Map.put_new(:updated_at, now)
  end

  defp ensure_updated_at(record) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    Map.put(record, :updated_at, now)
  end
end
