defmodule GiTF.Knowledge.PageIndex do
  @moduledoc """
  Secondary index for `:knowledge_pages` keyed by `{sector_id, slug} → id`.

  The Archive's primary key is the page id. Most read paths (graph
  traversal, backlink maintenance, retrieval) start from a slug, so
  every lookup used to do `Archive.filter/2` — a full ETS scan over the
  collection. With backlink maintenance touching every linked target on
  each page write, a 20-link page produced ~40 full scans.

  This module maintains a small ETS bag of `{sector_or_nil, slug, id}`
  triples that `GiTF.Knowledge.Page` writes on every `put/1` and
  `delete/2`. Reads do `:ets.lookup_element/3` then `Archive.get/2`
  (already O(1) by id).

  ## Correctness

  The cache is rebuilt from the Archive on first lookup if it's empty,
  or on demand via `rebuild/0`. Misses are not destructive — `Page.get/2`
  falls back to `Archive.filter/2` if the index returns nothing, so a
  drift between the index and the Archive only costs performance, never
  correctness.
  """

  alias GiTF.Archive

  @collection :knowledge_pages
  @table :gitf_knowledge_page_index

  @doc """
  Returns the page id for `{sector_id, slug}` or `nil` if not indexed.

  Triggers a one-time rebuild if the table is empty but the Archive
  collection has entries — covers the cold-boot case where the index
  hasn't been populated yet.
  """
  @spec get(String.t() | nil, String.t()) :: String.t() | nil
  def get(sector_id, slug) do
    ensure_table()
    maybe_rebuild_if_empty()

    case :ets.lookup(@table, {sector_id, slug}) do
      [{_, id}] -> id
      [] -> nil
    end
  end

  @doc "Records `id` for `{sector_id, slug}`. Idempotent."
  @spec put(String.t() | nil, String.t(), String.t()) :: :ok
  def put(sector_id, slug, id) do
    ensure_table()
    :ets.insert(@table, {{sector_id, slug}, id})
    :ok
  end

  @doc "Removes the entry for `{sector_id, slug}`. Idempotent."
  @spec delete(String.t() | nil, String.t()) :: :ok
  def delete(sector_id, slug) do
    ensure_table()
    :ets.delete(@table, {sector_id, slug})
    :ok
  end

  @doc """
  Rebuilds the index from the Archive. O(N) over the collection;
  intended for cold boot or after operator maintenance.
  """
  @spec rebuild() :: :ok
  def rebuild do
    ensure_table()
    :ets.delete_all_objects(@table)

    Archive.all(@collection)
    |> Enum.each(fn p ->
      :ets.insert(@table, {{p[:sector_id], p[:slug]}, p[:id]})
    end)

    :ok
  end

  # -- Internals -------------------------------------------------------------

  defp maybe_rebuild_if_empty do
    case :ets.info(@table, :size) do
      0 ->
        # Only rebuild if the Archive actually has rows; otherwise the
        # empty table is correct.
        case Archive.all(@collection) do
          [] -> :ok
          _ -> rebuild()
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end
end
