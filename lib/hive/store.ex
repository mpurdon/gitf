defmodule Hive.Store do
  @moduledoc """
  Pure-Elixir key-value store backed by an ETF (Erlang Term Format) file.

  Provides a Repo-like CRUD interface for Hive entities using plain maps.
  Data is stored as a single `.hive/store/hive.etf` file.

  Concurrent cross-process safety is achieved via:
  - `mkdir`-based advisory locking (POSIX `mkdir` is atomic)
  - Atomic `rename(2)` for writes (write to `.tmp`, rename into place)
  - Lock-free reads (readers always see a complete, consistent snapshot)
  """

  use GenServer

  @name __MODULE__
  @lock_stale_seconds 5
  @lock_steal_attempts 500
  @cache_table :hive_store_cache

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

    with_lock(fn data ->
      col = Map.get(data, collection, %{})
      col = Map.put(col, record.id, record)
      Map.put(data, collection, col)
    end)

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

    with_lock(fn data ->
      col = Map.get(data, collection, %{})
      col = Map.put(col, record.id, record)
      Map.put(data, collection, col)
    end)

    {:ok, record}
  end

  @doc "Deletes a record by collection and ID."
  @spec delete(atom(), String.t()) :: :ok
  def delete(collection, id) do
    with_lock(fn data ->
      col = Map.get(data, collection, %{})
      col = Map.delete(col, id)
      Map.put(data, collection, col)
    end)

    :ok
  end

  @doc "Returns all records in a collection."
  @spec all(atom()) :: [map()]
  def all(collection) do
    data = read_data()
    data |> Map.get(collection, %{}) |> Map.values()
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

      Store.transact(fn data ->
        job = get_in(data, [:jobs, job_id])
        dep = %{id: Hive.ID.generate(:jdp), job_id: job_id, depends_on_id: other_id}
        data
        |> put_in([:jobs, job_id], %{job | status: "blocked"})
        |> put_in([:job_dependencies, dep.id], dep)
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

    data_path = Path.join(data_dir, "hive.etf")
    lock_path = Path.join(data_dir, ".lock")

    # Store paths in persistent_term so API functions can access them
    # without going through the GenServer process
    :persistent_term.put({__MODULE__, :data_path}, data_path)
    :persistent_term.put({__MODULE__, :lock_path}, lock_path)

    # Create ETS read cache
    init_cache()

    # Run migrations after store is initialized
    Hive.Migrations.migrate!()

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
            # Existing data may contain atoms not yet loaded — fall back to unsafe
            :erlang.binary_to_term(binary)
        end
      {:error, :enoent} -> %{}
    end
  end

  defp write_data(data) do
    path = data_path()
    tmp_path = path <> ".tmp"
    binary = :erlang.term_to_binary(data)
    File.write!(tmp_path, binary)
    File.rename!(tmp_path, path)
    cache_put(data)
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

  defp cache_put(data) do
    :ets.insert(@cache_table, {:data, data})
  rescue
    ArgumentError -> :ok
  end

  defp with_lock(mutate_fn) do
    acquire_lock()

    try do
      data = read_data()
      new_data = mutate_fn.(data)
      write_data(new_data)
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
    Map.put(record, :id, Hive.ID.generate(prefix))
  end

  defp collection_prefix(:combs), do: :cmb
  defp collection_prefix(:bees), do: :bee
  defp collection_prefix(:jobs), do: :job
  defp collection_prefix(:quests), do: :qst
  defp collection_prefix(:waggles), do: :wag
  defp collection_prefix(:costs), do: :cst
  defp collection_prefix(:cells), do: :cel
  defp collection_prefix(:job_dependencies), do: :jdp
  defp collection_prefix(:councils), do: :cnl
  defp collection_prefix(:quest_phase_transitions), do: :qpt
  defp collection_prefix(:comb_research_cache), do: :crc
  defp collection_prefix(:research_file_index), do: :rfi
  defp collection_prefix(:verification_results), do: :vrf
  defp collection_prefix(:context_snapshots), do: :ctx
  defp collection_prefix(:model_reputation), do: :mrp
  defp collection_prefix(:council_reputation), do: :crp
  defp collection_prefix(:expert_reputation), do: :erp
  defp collection_prefix(_), do: :hiv

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
