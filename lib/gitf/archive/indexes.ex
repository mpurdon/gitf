defmodule GiTF.Archive.Indexes do
  @moduledoc "Secondary index maintenance for Archive collections."

  @specs %{
    ops: [:status, :mission_id],
    op_dependencies: [:op_id, :depends_on_id]
  }

  @doc "Returns the index specification map."
  @spec specs() :: %{atom() => [atom()]}
  def specs, do: @specs

  @doc "Returns the ETS table name for a given collection/field index."
  @spec index_table(atom(), atom()) :: atom()
  def index_table(col, field), do: :"gitf_idx_#{col}_#{field}"

  @doc "Initialize all index tables. Called during Archive startup."
  @spec init_tables() :: :ok
  def init_tables do
    heir_pid = GiTF.Archive.TableHeir.pid()

    for {col, fields} <- @specs, field <- fields do
      tab = index_table(col, field)

      case :ets.info(tab) do
        :undefined ->
          opts = [:bag, :named_table, :public, read_concurrency: true]
          opts = if is_pid(heir_pid), do: opts ++ [{:heir, heir_pid, :transfer}], else: opts
          :ets.new(tab, opts)
          if is_pid(heir_pid), do: GiTF.Archive.TableHeir.register(tab)

        _ ->
          :ok
      end
    end

    :ok
  end

  @doc "Clear all index tables. Called during Archive re-init."
  @spec clear_tables() :: :ok
  def clear_tables do
    for {col, fields} <- @specs, field <- fields do
      tab = index_table(col, field)
      if :ets.info(tab) != :undefined, do: :ets.delete_all_objects(tab)
    end

    :ok
  end

  @doc "Clear index tables for a single collection."
  @spec clear_collection(atom()) :: :ok
  def clear_collection(col) do
    case Map.get(@specs, col) do
      nil ->
        :ok

      fields ->
        for field <- fields do
          tab = index_table(col, field)
          if :ets.info(tab) != :undefined, do: :ets.delete_all_objects(tab)
        end

        :ok
    end
  end

  @doc "Delete all index tables."
  @spec delete_tables() :: :ok
  def delete_tables do
    for {col, fields} <- @specs, field <- fields do
      tab = index_table(col, field)

      if :ets.info(tab) != :undefined do
        try do
          :ets.delete(tab)
        rescue
          _ -> :ok
        end
      end
    end

    :ok
  end

  @doc "Update indexes when a record is inserted or updated."
  @spec on_put(atom(), map() | nil, map()) :: :ok
  def on_put(col, old_record, new_record) do
    case Map.get(@specs, col) do
      nil ->
        :ok

      fields ->
        id = new_record.id

        for field <- fields do
          tab = index_table(col, field)
          new_val = Map.get(new_record, field)

          if old_record do
            old_val = Map.get(old_record, field)

            if old_val != new_val do
              :ets.delete_object(tab, {old_val, id})
              :ets.insert(tab, {new_val, id})
            end
          else
            :ets.insert(tab, {new_val, id})
          end
        end

        :ok
    end
  end

  @doc "Remove index entries when a record is deleted."
  @spec on_delete(atom(), map()) :: :ok
  def on_delete(col, record) do
    case Map.get(@specs, col) do
      nil ->
        :ok

      fields ->
        for field <- fields do
          tab = index_table(col, field)
          val = Map.get(record, field)
          :ets.delete_object(tab, {val, record.id})
        end

        :ok
    end
  end

  @doc "Lookup record IDs matching a field value. Returns list of IDs."
  @spec lookup(atom(), atom(), term()) :: [String.t()]
  def lookup(col, field, value) do
    tab = index_table(col, field)
    :ets.lookup(tab, value) |> Enum.map(&elem(&1, 1))
  rescue
    ArgumentError -> []
  end

  @doc "Count records matching a field value without fetching."
  @spec count(atom(), atom(), term()) :: non_neg_integer()
  def count(col, field, value) do
    tab = index_table(col, field)
    :ets.select_count(tab, [{{value, :_}, [], [true]}])
  rescue
    ArgumentError -> 0
  end
end
