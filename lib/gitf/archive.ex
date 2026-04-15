defmodule GiTF.Archive do
  @moduledoc """
  Pure-Elixir key-value store backed by an ETF (Erlang Term Format) file.

  Provides a Repo-like CRUD interface for GiTF entities using plain maps.
  Data is stored as a single `.gitf/store/section.etf` file.

  Concurrent cross-process safety is achieved via:
  - `mkdir`-based advisory locking (POSIX `mkdir` is atomic)
  - Atomic `rename(2)` for writes (write to `.tmp`, rename into place)
  - Lock-free reads (readers always see a complete, consistent snapshot)
  """

  use GenServer

  @name __MODULE__
  @lock_stale_seconds 120
  @lock_steal_attempts 500
  @cache_table :gitf_store_cache
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
    data = read_data()
    get_in(data, [collection, id])
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

  The `update_fn` receives the current record and must return the updated record.
  Returns `{:ok, updated_record}` or `{:error, :not_found}`.

  ## Example

      Archive.update(:ops, op_id, fn op ->
        Map.merge(op, %{branch: "ghost/abc", files_changed: 3})
      end)
  """
  @spec update(atom(), String.t(), (map() -> map())) :: {:ok, map()} | {:error, :not_found}
  def update(collection, id, update_fn) when is_function(update_fn, 1) do
    with_lock(
      fn data ->
        col = Map.get(data, collection, %{})

        case Map.get(col, id) do
          nil ->
            # Signal not-found through process dictionary (lock fn must return data)
            Process.put(:archive_update_result, {:error, :not_found})
            data

          record ->
            updated = record |> update_fn.() |> ensure_updated_at()
            Process.put(:archive_update_result, {:ok, updated})
            col = Map.put(col, id, updated)
            Map.put(data, collection, col)
        end
      end,
      collection
    )

    case Process.delete(:archive_update_result) do
      {:ok, updated} -> {:ok, updated}
      {:error, :not_found} -> {:error, :not_found}
      nil -> {:error, :not_found}
    end
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
    # Per-collection cache: avoids Map.values() conversion on every call
    case collection_cache_get(collection) do
      {:ok, list} ->
        list

      :miss ->
        data = read_data()
        list = data |> Map.get(collection, %{}) |> Map.values()
        collection_cache_put(collection, list)
        list
    end
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

    data_path = Path.join(data_dir, "section.etf")
    lock_path = Path.join(data_dir, ".lock")

    # Archive paths in persistent_term so API functions can access them
    # without going through the GenServer process
    :persistent_term.put({__MODULE__, :data_path}, data_path)
    :persistent_term.put({__MODULE__, :lock_path}, lock_path)

    # Create ETS read cache
    init_cache()

    # Run migrations after store is initialized
    GiTF.Migrations.migrate!()

    {:ok, %{data_dir: data_dir, data_path: data_path, lock_path: lock_path}}
  end

  # -- File I/O (lock-free reads, mkdir-locked writes) -----------------------

  defp data_path, do: :persistent_term.get({__MODULE__, :data_path})
  defp lock_path, do: :persistent_term.get({__MODULE__, :lock_path})

  defp read_data do
    case cache_get() do
      {:ok, data} ->
        data

      :miss ->
        data = read_data_from_disk()
        cache_put(data)
        data
    end
  end

  defp read_data_from_disk do
    case File.read(data_path()) do
      {:ok, binary} ->
        try do
          :erlang.binary_to_term(binary, [:safe])
        rescue
          ArgumentError ->
            try do
              # Existing data may contain atoms not yet loaded — fall back to unsafe
              :erlang.binary_to_term(binary)
            rescue
              _ ->
                # Fully corrupted — try backup
                recover_from_backup()
            end
        catch
          _, _ ->
            recover_from_backup()
        end

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        require Logger
        Logger.error("Archive read failed: #{inspect(reason)}, trying backup")
        recover_from_backup()
    end
  end

  defp recover_from_backup do
    require Logger
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
            File.write(data_path(), binary)
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
          _ -> :ok
        end

        %{}

      data ->
        data
    end
  end

  defp write_data(data, changed_collection) do
    path = data_path()
    tmp_path = path <> ".tmp"
    binary = :erlang.term_to_binary(data)

    with :ok <- File.write(tmp_path, binary),
         :ok <- File.rename(tmp_path, path) do
      cache_put(data, changed_collection)
      maybe_backup(path, binary)
    else
      {:error, reason} ->
        require Logger
        Logger.error("Archive write failed: #{inspect(reason)}")
        # Still update cache so in-memory state is consistent
        cache_put(data, changed_collection)
        GiTF.Telemetry.emit([:gitf, :store, :write_error], %{}, %{reason: reason})
    end
  end

  defp maybe_backup(path, binary) do
    backup_path = path <> ".bak"

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
      rotate_backups(path)
      File.write(backup_path, binary)
    end
  rescue
    _ -> :ok
  end

  # Rotate backups: .bak -> .bak.2, .bak.2 -> .bak.3, etc.
  defp rotate_backups(path) do
    (@backup_generations - 1)..1//-1
    |> Enum.each(fn gen ->
      src = if gen == 1, do: path <> ".bak", else: path <> ".bak.#{gen}"
      dst = path <> ".bak.#{gen + 1}"
      if File.exists?(src), do: File.rename(src, dst)
    end)
  rescue
    _ -> :ok
  end

  # -- ETS cache ---------------------------------------------------------------

  defp init_cache do
    :ets.new(@cache_table, [:named_table, :public, :set, read_concurrency: true])
    # Warm cache from disk
    data = read_data_from_disk()
    cache_put(data)
  rescue
    ArgumentError -> :ok
  end

  defp cache_get do
    case :ets.lookup(@cache_table, :data) do
      [{:data, data}] -> {:ok, data}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp cache_put(data, invalidate_collection \\ nil) do
    :ets.insert(@cache_table, {:data, data})

    case invalidate_collection do
      nil -> invalidate_all_collection_caches()
      col when is_atom(col) -> invalidate_collection_cache(col)
    end
  rescue
    ArgumentError -> :ok
  end

  defp collection_cache_get(collection) do
    case :ets.lookup(@cache_table, {:collection, collection}) do
      [{{:collection, ^collection}, list}] -> {:ok, list}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp collection_cache_put(collection, list) do
    :ets.insert(@cache_table, {{:collection, collection}, list})
  rescue
    ArgumentError -> :ok
  end

  defp invalidate_all_collection_caches do
    :ets.select_delete(@cache_table, [
      {{{:collection, :_}, :_}, [], [true]}
    ])
  rescue
    ArgumentError -> :ok
  end

  defp invalidate_collection_cache(collection) do
    :ets.delete(@cache_table, {:collection, collection})
  rescue
    ArgumentError -> :ok
  end

  defp with_lock(mutate_fn, collection \\ nil) do
    acquire_lock()

    try do
      data = read_data()
      new_data = mutate_fn.(data)
      write_data(new_data, collection)
    after
      release_lock()
    end
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
