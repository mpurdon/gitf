defmodule GiTF.Archive do
  @moduledoc """
  Pure-Elixir key-value store backed by per-collection ETF files.

  Each collection is persisted as `<data_dir>/<collection>.etf` with a
  `manifest.etf` tracking the known collection set. Only dirty (changed)
  collections are re-serialized on write.

  Concurrent cross-process safety is achieved via:
  - `mkdir`-based advisory locking (POSIX `mkdir` is atomic)
  - Atomic `rename(2)` for writes (write to `.tmp`, rename into place)
  - Lock-free reads (readers always see a complete, consistent snapshot)
  """

  use GenServer
  require Logger

  alias GiTF.Archive.Indexes

  @name __MODULE__
  @indexes_enabled true
  @lock_stale_seconds 120
  @lock_steal_attempts 500
  @backup_interval_seconds 300
  @backup_generations 3

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

    with_lock(
      fn data ->
        col = Map.get(data, collection, %{})
        col = Map.put(col, record.id, record)
        Map.put(data, collection, col)
      end,
      collection
    )

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

    with_lock(
      fn data ->
        col = Map.get(data, collection, %{})
        col = Map.put(col, record.id, record)
        Map.put(data, collection, col)
      end,
      collection
    )

    {:ok, record}
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
    with_lock(
      fn data ->
        col = Map.get(data, collection, %{})

        case Map.get(col, id) do
          nil ->
            {data, {:error, :not_found}}

          record ->
            try do
              case update_fn.(record) do
                {:error, reason} ->
                  {data, {:error, reason}}

                {:ok, updated, metadata} when is_map(updated) ->
                  updated = ensure_updated_at(updated)
                  col = Map.put(col, id, updated)
                  new_data = Map.put(data, collection, col)
                  {new_data, {:ok, updated, metadata}}

                {:ok, updated} when is_map(updated) ->
                  updated = ensure_updated_at(updated)
                  col = Map.put(col, id, updated)
                  new_data = Map.put(data, collection, col)
                  {new_data, {:ok, updated}}

                updated when is_map(updated) ->
                  updated = ensure_updated_at(updated)
                  col = Map.put(col, id, updated)
                  new_data = Map.put(data, collection, col)
                  {new_data, {:ok, updated}}

                other ->
                  {data, {:error, {:bad_update_fn_return, other}}}
              end
            rescue
              e ->
                Logger.error(
                  "Archive.update closure for #{inspect(collection)}/#{id} raised: " <>
                    Exception.format(:error, e, __STACKTRACE__)
                )

                {data, {:error, {:exception, e}}}
            end
        end
      end,
      collection
    )
  end

  @doc "Deletes a record by collection and ID."
  @spec delete(atom(), String.t()) :: :ok
  def delete(collection, id) do
    with_lock(
      fn data ->
        col = Map.get(data, collection, %{})
        col = Map.delete(col, id)
        Map.put(data, collection, col)
      end,
      collection
    )

    :ok
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

  @doc "Counts records in a collection."
  @spec count(atom()) :: non_neg_integer()
  def count(collection) do
    all(collection) |> length()
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
  Executes multiple mutations in a single lock/read/write cycle.

  The function receives the full store data and must return the modified data.
  This prevents orphaned records from crashes between separate lock cycles.

  ## Example

      Archive.transact(fn data ->
        op = get_in(data, [:ops, op_id])
        dep = %{id: GiTF.ID.generate(:jdp), op_id: op_id, depends_on_id: other_id}
        data
        |> put_in([:ops, op_id], %{op | status: "blocked"})
        |> put_in([:op_dependencies, dep.id], dep)
      end)
  """
  @spec transact((map() -> map())) :: :ok
  def transact(fun) when is_function(fun, 1) do
    with_lock(fun)
    :ok
  end

  @doc "Updates all matching records with an update function. Returns count updated."
  @spec update_matching(atom(), (map() -> boolean()), (map() -> map())) :: non_neg_integer()
  def update_matching(collection, filter_fun, update_fun) do
    # Perform filter + update inside the lock to avoid TOCTOU races
    ref = make_ref()
    Process.put(ref, 0)

    with_lock(fn data ->
      col = Map.get(data, collection, %{})
      matching = col |> Map.values() |> Enum.filter(filter_fun)
      Process.put(ref, length(matching))

      if matching == [] do
        data
      else
        updated_col =
          Enum.reduce(matching, col, fn record, acc ->
            updated = update_fun.(record) |> ensure_updated_at()
            Map.put(acc, record.id, updated)
          end)

        Map.put(data, collection, updated_col)
      end
    end)

    Process.delete(ref) || 0
  end

  # -- GenServer callbacks ---------------------------------------------------

  @impl true
  def init(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)
    File.mkdir_p!(data_dir)

    # Legacy path kept for migration detection
    data_path = Path.join(data_dir, "section.etf")
    lock_path = Path.join(data_dir, ".lock")

    # Archive paths in persistent_term so API functions can access them
    # without going through the GenServer process
    :persistent_term.put({__MODULE__, :data_path}, data_path)
    :persistent_term.put({__MODULE__, :data_dir}, data_dir)
    :persistent_term.put({__MODULE__, :lock_path}, lock_path)

    # Create per-collection ETS tables from disk data
    init_store()

    # Run migrations after store is initialized
    GiTF.Migrations.migrate!()

    {:ok, %{data_dir: data_dir, data_path: data_path, lock_path: lock_path}}
  end

  # -- Path helpers -----------------------------------------------------------

  defp data_path, do: :persistent_term.get({__MODULE__, :data_path})
  defp data_dir, do: :persistent_term.get({__MODULE__, :data_dir})
  defp lock_path, do: :persistent_term.get({__MODULE__, :lock_path})
  defp collection_path(col), do: Path.join(data_dir(), "#{col}.etf")
  defp manifest_path, do: Path.join(data_dir(), "manifest.etf")

  # -- File I/O (lock-free reads, mkdir-locked writes) -----------------------

  defp read_data do
    cols = known_collections()

    if MapSet.size(cols) == 0 do
      %{}
    else
      for col <- cols, into: %{} do
        records = :ets.tab2list(table_name(col)) |> Map.new()
        {col, records}
      end
    end
  end

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

  # -- Per-collection write --------------------------------------------------

  defp write_dirty(data, dirty_collections) do
    for col <- dirty_collections do
      col_data = Map.get(data, col, %{})
      binary = :erlang.term_to_binary(col_data)
      path = collection_path(col)
      tmp = path <> ".tmp"

      with :ok <- File.write(tmp, binary),
           :ok <- File.rename(tmp, path) do
        maybe_backup_collection(col, binary)
      else
        {:error, reason} ->
          Logger.error("Archive write failed for #{col}: #{inspect(reason)}")

          GiTF.Telemetry.emit([:gitf, :store, :write_error], %{}, %{
            collection: col,
            reason: reason,
            cache_disk_divergent: true
          })
      end
    end

    maybe_update_manifest()
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
    manifest = read_manifest()

    collections =
      case manifest do
        %{collections: cols} when is_list(cols) -> cols
        _ -> []
      end

    for col <- collections, into: %{} do
      {col, read_collection_from_disk(col)}
    end
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

  defp sync_ets(data, changed_collection) do
    if changed_collection do
      col_data = Map.get(data, changed_collection, %{})
      ensure_table(changed_collection)
      :ets.delete_all_objects(table_name(changed_collection))
      Indexes.clear_collection(changed_collection)

      for {id, record} <- col_data do
        :ets.insert(table_name(changed_collection), {id, record})
        Indexes.on_put(changed_collection, nil, record)
      end
    else
      # transact — may touch multiple collections
      for {col, records} <- data, is_atom(col) do
        ensure_table(col)
        :ets.delete_all_objects(table_name(col))
        Indexes.clear_collection(col)

        for {id, record} <- records do
          :ets.insert(table_name(col), {id, record})
          Indexes.on_put(col, nil, record)
        end
      end
    end
  end

  # `mutate_fn` may return either the new data map, or a `{new_data, result}`
  # tuple. In the latter case, `with_lock` returns `result`; otherwise it
  # returns `:ok`. This lets callers smuggle values (e.g. the updated record,
  # transition metadata, error tags) out of the lock closure without using
  # the process dictionary (which is not reentrancy-safe).
  defp with_lock(mutate_fn, collection \\ nil) do
    acquire_lock()

    try do
      data = read_data()

      case mutate_fn.(data) do
        {new_data, result} when is_map(new_data) ->
          dirty = if collection, do: MapSet.new([collection]), else: diff_collections(data, new_data)
          sync_ets(new_data, collection)
          write_dirty(new_data, dirty)
          result

        new_data when is_map(new_data) ->
          dirty = if collection, do: MapSet.new([collection]), else: diff_collections(data, new_data)
          sync_ets(new_data, collection)
          write_dirty(new_data, dirty)
          :ok
      end
    after
      release_lock()
    end
  end

  defp diff_collections(old, new) do
    all_keys = MapSet.union(MapSet.new(Map.keys(old)), MapSet.new(Map.keys(new)))

    all_keys
    |> Enum.filter(fn k -> Map.get(old, k) != Map.get(new, k) end)
    |> MapSet.new()
  end

  defp acquire_lock, do: acquire_lock(0)

  defp acquire_lock(attempts) do
    lock = lock_path()

    case File.mkdir(lock) do
      :ok ->
        write_pid_file(lock)
        :ok

      {:error, :eexist} ->
        cond do
          lock_owner_dead?(lock) ->
            # Dead process fast-path — steal immediately
            steal_lock(lock)
            acquire_lock(0)

          lock_stale?(lock) ->
            # Stale lock from a crashed process — steal it
            steal_lock(lock)
            acquire_lock(0)

          attempts >= @lock_steal_attempts ->
            # ~5s of waiting (500 * 10ms) — force steal
            steal_lock(lock)
            acquire_lock(0)

          true ->
            Process.sleep(10)
            acquire_lock(attempts + 1)
        end
    end
  end

  defp release_lock do
    lock = lock_path()
    pid_file = Path.join(lock, "pid")
    File.rm(pid_file)
    File.rmdir(lock)
  end

  defp write_pid_file(lock_dir) do
    pid_file = Path.join(lock_dir, "pid")
    File.write(pid_file, :erlang.pid_to_list(self()))
  end

  defp lock_owner_dead?(lock_dir) do
    pid_file = Path.join(lock_dir, "pid")

    case File.read(pid_file) do
      {:ok, pid_str} ->
        try do
          pid = :erlang.list_to_pid(String.to_charlist(pid_str))
          not Process.alive?(pid)
        rescue
          _ -> false
        end

      {:error, _} ->
        # No PID file — can't determine, fall through to stale check
        false
    end
  end

  defp steal_lock(lock_dir) do
    pid_file = Path.join(lock_dir, "pid")
    File.rm(pid_file)
    File.rmdir(lock_dir)
  end

  defp lock_stale?(lock_path) do
    case File.stat(lock_path, time: :posix) do
      {:ok, %{mtime: mtime}} ->
        System.os_time(:second) - mtime > @lock_stale_seconds

      {:error, _} ->
        # Lock disappeared between check and stat — not stale
        false
    end
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
