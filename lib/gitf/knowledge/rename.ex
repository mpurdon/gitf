defmodule GiTF.Knowledge.Rename do
  @moduledoc """
  Detects and propagates page renames done outside the Factory's
  awareness.

  When an operator renames `Sectors/<id>/Pages/foo.md` to `bar.md` in
  Obsidian (or via `mv` on disk), our Archive index still references
  the old slug `foo`. Other pages may also still carry `[[foo]]`
  wikilinks (if the operator used a plain `mv`) or already point to
  `[[bar]]` (if Obsidian's rename rewrote them). This module
  reconciles both shapes.

  ## Detection

  A rename is identified by the content_hash heuristic:

    * `foo.md` is in the Archive with hash H but no longer on disk.
    * Some file `bar.md` is on disk in the same `Pages/` directory
      with hash H but no Archive entry.

  If exactly one orphan file matches a missing page's hash, we treat
  it as that page renamed. Multiple-match (two files same hash) and
  hash-drift (operator edited + renamed in one go) are surfaced as
  warnings so the operator can resolve them deliberately.

  ## Propagation

  For each detected rename `{old_slug, new_slug}`:

    1. The Archive record's `slug`, `file_path`, and `id` keys are
       updated to point at the new file.
    2. `[[old_slug]]` wikilinks in every page whose `links_in`
       contains `old_slug` are rewritten to `[[new_slug]]`. The body
       is read from disk, regex-rewritten, and put back via
       `Knowledge.Page.put/1` (which recomputes hash + parsed links).
       Obsidian-renamed pages already have `[[new_slug]]` so this
       step is a no-op for them.
    3. The renamed page itself is reindexed so its `links_out` /
       `links_in` reflect the post-rename body.

  ## CLI

      gitf knowledge rescan --sector <id>

  Triggers `rescan/2` which combines detection + propagation. Safe to
  run repeatedly — idempotent once the index is consistent with disk.
  """

  require Logger

  alias GiTF.Archive
  alias GiTF.Knowledge.{Link, Page}
  alias GiTF.Vault.File, as: VFile
  alias GiTF.Vault.Path, as: VPath

  @collection :knowledge_pages

  @type rename :: %{
          old_slug: String.t(),
          new_slug: String.t(),
          old_file_path: String.t(),
          new_file_path: String.t(),
          content_hash: String.t()
        }

  @type rescan_result :: %{
          renames: [rename()],
          backlinks_rewritten: non_neg_integer(),
          ambiguous: [{String.t(), [String.t()]}],
          hash_drift: [String.t()],
          errors: [{String.t(), term()}]
        }

  @doc """
  Detects renames in `sector_id` without applying them. Returns the
  list of matched renames plus diagnostic buckets for the cases that
  require operator attention.
  """
  @spec detect(String.t() | nil) :: %{
          renames: [rename()],
          ambiguous: [{String.t(), [String.t()]}],
          hash_drift: [String.t()]
        }
  def detect(sector_id) do
    pages = Page.list(sector_id)
    {missing, _present} = Enum.split_with(pages, &file_missing?/1)

    orphan_files = orphans_on_disk(sector_id, pages)
    orphan_index = index_orphans_by_hash(orphan_files)

    Enum.reduce(missing, %{renames: [], ambiguous: [], hash_drift: []}, fn page, acc ->
      case Map.get(orphan_index, page[:content_hash], []) do
        [] ->
          # File gone, no hash match — either deleted, or operator
          # edited + renamed simultaneously (hash drifted).
          %{acc | hash_drift: [page[:slug] | acc.hash_drift]}

        [orphan_path] ->
          rename = build_rename(page, orphan_path)
          %{acc | renames: [rename | acc.renames]}

        [_ | _] = paths ->
          %{acc | ambiguous: [{page[:slug], paths} | acc.ambiguous]}
      end
    end)
    |> Map.update!(:renames, &Enum.reverse/1)
    |> Map.update!(:hash_drift, &Enum.reverse/1)
    |> Map.update!(:ambiguous, &Enum.reverse/1)
  end

  @doc """
  Detect + apply. Returns the same shape as `detect/1` plus a count of
  backlink rewrites and an error list.
  """
  @spec rescan(String.t() | nil, keyword()) :: rescan_result()
  def rescan(sector_id, opts \\ []) do
    dry = Keyword.get(opts, :dry_run, false)
    detection = detect(sector_id)

    {rewrites, errors} =
      Enum.reduce(detection.renames, {0, []}, fn rename, {rcount, errs} ->
        if dry do
          {rcount, errs}
        else
          case apply_rename(sector_id, rename) do
            {:ok, n} -> {rcount + n, errs}
            {:error, reason} -> {rcount, [{rename.old_slug, reason} | errs]}
          end
        end
      end)

    %{
      renames: detection.renames,
      backlinks_rewritten: rewrites,
      ambiguous: detection.ambiguous,
      hash_drift: detection.hash_drift,
      errors: Enum.reverse(errors)
    }
  end

  # -- Detection helpers -----------------------------------------------------

  defp file_missing?(page), do: not File.exists?(page[:file_path])

  defp orphans_on_disk(sector_id, pages) do
    case GiTF.gitf_dir() do
      {:ok, root} ->
        dir = VPath.pages_dir(root, sector_id)

        if File.dir?(dir) do
          known = MapSet.new(pages, & &1[:file_path])

          dir
          |> File.ls!()
          |> Enum.map(&Path.join(dir, &1))
          |> Enum.filter(&(Path.extname(&1) == ".md"))
          |> Enum.reject(&MapSet.member?(known, &1))
        else
          []
        end

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp index_orphans_by_hash(paths) do
    Enum.reduce(paths, %{}, fn path, acc ->
      # `VFile.read/1` produces the same hash format Page.put/1 stores
      # (lowercase hex SHA-256). Going through the canonical helper
      # keeps the two definitions from drifting silently.
      case VFile.read(path) do
        {:ok, _body, hash} ->
          Map.update(acc, hash, [path], &[path | &1])

        _ ->
          acc
      end
    end)
  end

  defp build_rename(page, orphan_path) do
    new_slug =
      orphan_path
      |> Path.basename(".md")
      |> VPath.slugify()

    %{
      old_slug: page[:slug],
      new_slug: new_slug,
      old_file_path: page[:file_path],
      new_file_path: orphan_path,
      content_hash: page[:content_hash]
    }
  end

  # -- Application -----------------------------------------------------------

  defp apply_rename(sector_id, rename) do
    case Page.get(sector_id, rename.old_slug) do
      nil ->
        {:error, :record_gone}

      page ->
        with {:ok, body} <- File.read(rename.new_file_path),
             {:ok, _new_page} <-
               Page.put(%{
                 slug: rename.new_slug,
                 sector_id: sector_id,
                 title: page[:title],
                 body: body,
                 tags: page[:tags] || []
               }) do
          # Rewrite [[old]] → [[new]] in every page that still
          # references the old slug. Obsidian-rewrite case is a no-op
          # because the body no longer contains [[old]].
          rewrite_count = rewrite_backlinks(sector_id, page[:links_in] || [], rename)

          # Old file was moved (not duplicated); only the Archive row +
          # PageIndex entry need to go.
          Archive.delete(@collection, page[:id])
          GiTF.Knowledge.PageIndex.delete(sector_id, rename.old_slug)

          {:ok, rewrite_count}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp rewrite_backlinks(sector_id, source_slugs, rename) do
    Enum.reduce(source_slugs, 0, fn source_slug, acc ->
      case Page.get(sector_id, source_slug) do
        nil ->
          acc

        source ->
          rewrite_one_source(sector_id, source, rename, acc)
      end
    end)
  end

  defp rewrite_one_source(sector_id, source, rename, acc) do
    case File.read(source[:file_path]) do
      {:ok, body} ->
        new_body = Link.rewrite_target(body, rename.old_slug, rename.new_slug)

        cond do
          new_body != body ->
            # Plain-mv case: body still references the old slug.
            {:ok, _} =
              Page.put(%{
                slug: source[:slug],
                sector_id: sector_id,
                title: source[:title],
                body: new_body,
                tags: source[:tags] || []
              })

            acc + 1

          rename.old_slug in (source[:links_out] || []) ->
            # Obsidian-rewrite case: disk body already updated but our
            # Archive index still references the old slug. Refresh so
            # links_out reflects reality.
            _ = Page.reindex(sector_id, source[:slug])
            acc

          true ->
            acc
        end

      _ ->
        acc
    end
  end
end
