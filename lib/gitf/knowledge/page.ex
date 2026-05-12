defmodule GiTF.Knowledge.Page do
  @moduledoc """
  Wiki page CRUD with disk-canonical bodies and an Archive-cached index.

  The markdown body lives at a deterministic path under the Obsidian
  vault. The Archive holds an index record keyed by `{sector_id, slug}`
  with the content hash, parsed wikilinks, and (later) the embedding.

  When a page is created or updated, this module:

    1. Writes the body atomically to disk.
    2. Computes the content hash and parses outbound `[[slug]]` links.
    3. Upserts the index record.
    4. Updates the reciprocal `links_in` on every page this one links to,
       and removes the back-reference from any page it no longer links
       to. (`adjust_backlinks/3`.)

  The Archive update is *after* the disk write, so a crash between the
  two leaves the file on disk but the index out of sync — `reindex/2`
  rebuilds the record from disk on the next read.
  """

  require Logger

  alias GiTF.Archive
  alias GiTF.Knowledge.Link
  alias GiTF.Vault.File, as: VFile
  alias GiTF.Vault.Path, as: VPath

  @collection :knowledge_pages

  @type t :: %{
          required(:id) => String.t(),
          required(:slug) => String.t(),
          required(:sector_id) => String.t() | nil,
          required(:title) => String.t(),
          required(:file_path) => String.t(),
          required(:content_hash) => String.t(),
          required(:links_out) => [String.t()],
          required(:links_in) => [String.t()],
          required(:tags) => [String.t()],
          required(:updated_at) => DateTime.t(),
          optional(:embedding) => [float()] | nil,
          optional(:embedding_model) => String.t() | nil
        }

  # -- Public API ------------------------------------------------------------

  @doc """
  Creates or replaces a page. `slug` is normalised; `sector_id` may be nil
  (global). `body` is the markdown that lives on disk. `title` and `tags`
  default to derived/empty.

  Returns `{:ok, page}` on success.
  """
  @spec put(map()) :: {:ok, t()} | {:error, term()}
  def put(attrs) when is_map(attrs) do
    with {:ok, gitf_root} <- GiTF.gitf_dir(),
         {:ok, slug} <- fetch_slug(attrs),
         sector_id <- attrs[:sector_id] || attrs["sector_id"],
         body <- attrs[:body] || attrs["body"] || "",
         title <- attrs[:title] || attrs["title"] || derive_title(body, slug),
         tags <- normalize_tags(attrs[:tags] || attrs["tags"] || []),
         file_path <- VPath.page_file(gitf_root, sector_id, slug),
         {:ok, content_hash} <- VFile.write(file_path, body) do
      links_out = Link.parse_wikilinks(body)
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      existing = get(sector_id, slug)
      prior_out = prior_links_out(existing)

      record =
        case existing do
          nil ->
            %{
              slug: slug,
              sector_id: sector_id,
              title: title,
              file_path: file_path,
              content_hash: content_hash,
              links_out: links_out,
              links_in: [],
              tags: tags,
              updated_at: now,
              embedding: nil,
              embedding_model: nil
            }

          existing ->
            existing
            |> Map.merge(%{
              title: title,
              file_path: file_path,
              content_hash: content_hash,
              links_out: links_out,
              tags: tags,
              updated_at: now
            })
            # Embedding is invalidated when the body changes; the next
            # retrieval pass re-embeds and persists.
            |> maybe_invalidate_embedding(existing[:content_hash], content_hash)
        end

      {:ok, stored} = upsert(record)
      GiTF.Knowledge.PageIndex.put(stored[:sector_id], stored[:slug], stored[:id])
      :ok = adjust_backlinks(stored, prior_out, links_out)
      {:ok, stored}
    end
  end

  @doc "Returns the page record for `{sector_id, slug}` or nil."
  @spec get(String.t() | nil, String.t()) :: t() | nil
  def get(sector_id, slug) do
    slug = VPath.slugify(slug)

    case GiTF.Knowledge.PageIndex.get(sector_id, slug) do
      nil ->
        # Cold miss — fall back to a scan and prime the index. Covers the
        # case where a page existed before the index was introduced or a
        # crash desynced the cache from the Archive.
        case Archive.filter(@collection, fn p ->
               p[:slug] == slug and p[:sector_id] == sector_id
             end)
             |> List.first() do
          nil -> nil
          page -> tap(page, fn p -> GiTF.Knowledge.PageIndex.put(sector_id, slug, p[:id]) end)
        end

      id ->
        case Archive.get(@collection, id) do
          nil ->
            # Index points at a stale id — drop the entry and recurse to
            # do a fresh scan.
            GiTF.Knowledge.PageIndex.delete(sector_id, slug)
            get(sector_id, slug)

          page ->
            page
        end
    end
  end

  @doc "Returns all pages for `sector_id` (use `nil` for global pages)."
  @spec list(String.t() | nil) :: [t()]
  def list(sector_id) do
    Archive.filter(@collection, fn p -> p[:sector_id] == sector_id end)
  end

  @doc """
  Reads the body from disk for `{sector_id, slug}`. Returns
  `{:ok, body, hash_from_disk}` so callers can detect operator edits
  (record's `content_hash` differs from the disk hash → re-embed and
  re-link via `reindex/2`).
  """
  @spec read_body(String.t() | nil, String.t()) ::
          {:ok, binary(), String.t()} | {:error, term()}
  def read_body(sector_id, slug) do
    with {:ok, gitf_root} <- GiTF.gitf_dir() do
      VFile.read(VPath.page_file(gitf_root, sector_id, slug))
    end
  end

  @doc """
  Re-syncs the Archive record for `{sector_id, slug}` from disk. Used
  when the operator edited the file directly in Obsidian and the record's
  `content_hash` no longer matches.
  """
  @spec reindex(String.t() | nil, String.t()) :: {:ok, t()} | {:error, term()}
  def reindex(sector_id, slug) do
    case read_body(sector_id, slug) do
      {:ok, body, _hash} ->
        existing = get(sector_id, slug) || %{}
        title = existing[:title] || derive_title(body, slug)
        tags = existing[:tags] || []

        put(%{
          slug: slug,
          sector_id: sector_id,
          title: title,
          body: body,
          tags: tags
        })

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Deletes a page by `{sector_id, slug}`. Removes the file from disk,
  removes the record, and removes the back-reference from every page that
  linked TO it.

  Inbound links are left dangling on the source pages (their `links_out`
  still points at the now-missing slug); we don't rewrite operator-
  authored bodies. Lint surfaces these as broken links.
  """
  @spec delete(String.t() | nil, String.t()) :: :ok
  def delete(sector_id, slug) do
    slug = VPath.slugify(slug)

    case get(sector_id, slug) do
      nil ->
        :ok

      page ->
        VFile.rm(page[:file_path]) |> ignore()
        :ok = adjust_backlinks(page, page[:links_out], [])
        Archive.delete(@collection, page[:id])
        GiTF.Knowledge.PageIndex.delete(sector_id, slug)
        :ok
    end
  end

  # -- Backlink maintenance --------------------------------------------------

  # Updates `links_in` on every page that gained or lost a reference from
  # `page`. Backlinks are scoped to the same sector — a global page (sector
  # nil) referenced from a sector page is handled by allowing `target_sector`
  # to be `:any` when looking up the target. For now we keep it strict
  # (same sector) and global-page references are an explicit M3 follow-up.
  defp adjust_backlinks(%{} = page, prior_out, new_out) do
    added = new_out -- prior_out
    removed = prior_out -- new_out

    Enum.each(added, fn target_slug ->
      bump_links_in(page[:sector_id], target_slug, page[:slug], :add)
    end)

    Enum.each(removed, fn target_slug ->
      bump_links_in(page[:sector_id], target_slug, page[:slug], :remove)
    end)

    :ok
  end

  defp bump_links_in(sector_id, target_slug, source_slug, op) do
    case get(sector_id, target_slug) do
      nil ->
        # Target doesn't exist yet — that's a forward reference. We don't
        # auto-create stub pages; lint will flag it as a broken link.
        :ok

      target ->
        Archive.update(@collection, target[:id], fn t ->
          current = t[:links_in] || []

          new_links =
            case op do
              :add -> Enum.uniq([source_slug | current])
              :remove -> Enum.reject(current, &(&1 == source_slug))
            end

          Map.put(t, :links_in, new_links)
        end)
        |> ignore()

        :ok
    end
  end

  # -- Internals -------------------------------------------------------------

  defp upsert(record) do
    case get(record.sector_id, record.slug) do
      nil ->
        Archive.insert(@collection, record)

      existing ->
        Archive.update(@collection, existing[:id], fn _ ->
          # Carry the existing id through; everything else is replaced.
          Map.put(record, :id, existing[:id])
        end)
    end
  end

  defp prior_links_out(nil), do: []
  defp prior_links_out(%{links_out: out}) when is_list(out), do: out
  defp prior_links_out(_), do: []

  defp fetch_slug(attrs) do
    raw = attrs[:slug] || attrs["slug"]

    cond do
      is_binary(raw) and raw != "" ->
        {:ok, VPath.slugify(raw)}

      is_binary(attrs[:title] || attrs["title"]) ->
        case VPath.slugify(attrs[:title] || attrs["title"]) do
          "" -> {:error, :missing_slug}
          s -> {:ok, s}
        end

      true ->
        {:error, :missing_slug}
    end
  end

  defp derive_title(body, fallback_slug) do
    case Regex.run(~r/^#\s+(.+)$/m, body, capture: :all_but_first) do
      [title] -> String.trim(title)
      _ -> fallback_slug |> String.replace("-", " ") |> String.capitalize()
    end
  end

  defp normalize_tags(tags) when is_list(tags), do: Enum.map(tags, &to_string/1) |> Enum.uniq()
  defp normalize_tags(_), do: []

  defp maybe_invalidate_embedding(record, prior_hash, new_hash) do
    if prior_hash == new_hash do
      record
    else
      Map.merge(record, %{embedding: nil, embedding_model: nil})
    end
  end

  defp ignore(_), do: :ok
end
