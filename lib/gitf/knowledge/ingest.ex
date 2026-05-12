defmodule GiTF.Knowledge.Ingest do
  @moduledoc """
  Bulk-imports an existing markdown corpus into the wiki.

  Two usage modes:

    * `ingest_directory/3` — walks a directory of `.md` files, derives
      slugs from filenames, and upserts each as a `Knowledge.Page` in
      the target sector. Idempotent: re-running on the same corpus
      replaces existing pages with the latest disk content.
    * `reindex_sector/2` — re-reads every page already in a sector from
      disk, refreshes the Archive index (links, hash, embedding-
      invalidation). Used after operators bulk-edit pages in Obsidian
      outside the Factory's awareness.

  Why one and not the other: ingest copies *foreign* markdown into the
  wiki layout (filenames may not match our slug convention, paths are
  arbitrary). Reindex syncs the Archive to disk for files already in the
  vault — slugs and paths are already canonical.

  ## Slug derivation

      "Auth Flow.md"          → "auth-flow"
      "001_API Endpoints.md"  → "api-endpoints"   # numeric prefix stripped
      "subdir/sub-page.md"    → "sub-page"        # path segments dropped

  When two source files would produce the same slug we keep the first
  and log the duplicate. Operators who care about ordering should
  rename files to disambiguate.

  Files matching `_index.md`, `_kanban.md`, or any file in `Templates/`
  / `Daily Notes/` / `Missions/` / `Ghosts/` are skipped — those are
  Factory-owned and ingestion would clobber them on the next render.
  """

  require Logger

  alias GiTF.Knowledge.Page
  alias GiTF.Vault.Path, as: VPath

  @numeric_prefix ~r/^\d{1,4}_/
  @reserved_dirs ~w(Templates Missions Ghosts)
  @reserved_files ~w(_index.md _kanban.md README.md)

  @type ingest_result :: %{
          imported: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: [{Path.t(), term()}]
        }

  # -- Bulk ingest -----------------------------------------------------------

  @doc """
  Walks `dir` recursively and ingests every `.md` file as a page in
  `sector_id`. Returns a summary.

  Options:
    * `:tag` — additional tag applied to every imported page
    * `:dry_run` — when true, log what would happen and write nothing
  """
  @spec ingest_directory(Path.t(), String.t() | nil, keyword()) :: ingest_result()
  def ingest_directory(dir, sector_id, opts \\ []) when is_binary(dir) do
    if File.dir?(dir) do
      files = walk(dir)
      do_ingest(files, dir, sector_id, opts)
    else
      Logger.warning("Knowledge.Ingest: not a directory: #{dir}")
      %{imported: 0, skipped: 0, errors: [{dir, :enotdir}]}
    end
  end

  # 5MB cap per markdown file. Larger inputs are skipped, not read,
  # so a single huge file (or a `/dev/zero` symlink) can't OOM the BEAM.
  @max_ingest_size 5 * 1024 * 1024

  # `lstat` (not stat) so symlinks show up as :symlink and are rejected
  # before they can lead the walker outside the corpus root or into
  # files the operator never opted into.
  defp walk(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          full = Path.join(dir, entry)
          walk_entry(full, entry)
        end)

      {:error, _} ->
        []
    end
  end

  defp walk_entry(full, entry) do
    case File.lstat(full) do
      {:ok, %File.Stat{type: :directory}} when entry not in @reserved_dirs ->
        walk(full)

      {:ok, %File.Stat{type: :regular, size: size}}
      when size <= @max_ingest_size ->
        if Path.extname(entry) == ".md" and entry not in @reserved_files,
          do: [full],
          else: []

      {:ok, %File.Stat{type: :regular}} ->
        Logger.warning("Knowledge.Ingest: skipping #{full} — exceeds #{@max_ingest_size}-byte cap")
        []

      _ ->
        []
    end
  end

  defp do_ingest(files, _root, sector_id, opts) do
    extra_tag = opts[:tag]
    dry = opts[:dry_run] == true

    {imported, skipped, errors, _seen} =
      Enum.reduce(files, {0, 0, [], MapSet.new()}, fn file, {imp, skip, errs, seen} ->
        slug = slug_from_file(file)

        cond do
          slug == "" ->
            {imp, skip + 1, [{file, :empty_slug} | errs], seen}

          MapSet.member?(seen, slug) ->
            Logger.debug("Knowledge.Ingest: duplicate slug #{slug} from #{file}, skipping")
            {imp, skip + 1, errs, seen}

          true ->
            case ingest_one(file, slug, sector_id, extra_tag, dry) do
              :ok -> {imp + 1, skip, errs, MapSet.put(seen, slug)}
              {:error, reason} -> {imp, skip, [{file, reason} | errs], seen}
            end
        end
      end)

    %{imported: imported, skipped: skipped, errors: Enum.reverse(errors)}
  end

  defp ingest_one(file, slug, sector_id, extra_tag, dry) do
    with {:ok, body} <- File.read(file) do
      {title, body_without_h1} = extract_title(body, slug)

      tags =
        case extra_tag do
          tag when is_binary(tag) and tag != "" -> [tag]
          _ -> []
        end

      if dry do
        Logger.info("Knowledge.Ingest [dry]: would ingest #{slug} from #{file}")
        :ok
      else
        case Page.put(%{
               slug: slug,
               sector_id: sector_id,
               title: title,
               body: body_without_h1,
               tags: tags
             }) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  # -- Reindex --------------------------------------------------------------

  @doc """
  Re-reads every page in `sector_id` from disk and refreshes the Archive
  index (content hash, parsed links, embedding invalidation). Used after
  the operator has edited pages in Obsidian.

  Returns `%{rescanned, updated, missing, errors}`. A page is "updated"
  when the on-disk content_hash differs from the Archive's stored hash.
  """
  @spec reindex_sector(String.t() | nil, keyword()) :: %{
          rescanned: non_neg_integer(),
          updated: non_neg_integer(),
          missing: non_neg_integer(),
          errors: [{String.t(), term()}]
        }
  def reindex_sector(sector_id, _opts \\ []) do
    pages = Page.list(sector_id)

    {rescan, updated, missing, errors} =
      Enum.reduce(pages, {0, 0, 0, []}, fn p, {r, u, m, errs} ->
        case Page.read_body(sector_id, p.slug) do
          {:ok, _body, disk_hash} ->
            if disk_hash == p.content_hash do
              {r + 1, u, m, errs}
            else
              case Page.reindex(sector_id, p.slug) do
                {:ok, _} -> {r + 1, u + 1, m, errs}
                {:error, reason} -> {r + 1, u, m, [{p.slug, reason} | errs]}
              end
            end

          {:error, :enoent} ->
            {r + 1, u, m + 1, errs}

          {:error, reason} ->
            {r + 1, u, m, [{p.slug, reason} | errs]}
        end
      end)

    %{rescanned: rescan, updated: updated, missing: missing, errors: Enum.reverse(errors)}
  end

  # -- Helpers --------------------------------------------------------------

  defp slug_from_file(path) do
    path
    |> Path.basename(".md")
    |> String.replace(@numeric_prefix, "")
    |> VPath.slugify()
  end

  defp extract_title(body, fallback_slug) do
    case Regex.run(~r/^\s*#\s+(.+)$/m, body, capture: :all_but_first) do
      [title] ->
        # Drop the H1 line so it doesn't duplicate when we re-render
        # title + body. The Page renderer will re-emit it.
        body_without =
          body
          |> String.split(~r/\r?\n/, parts: 2)
          |> case do
            [_h1, rest] -> rest
            [single] -> single
          end
          |> String.trim_leading()

        {String.trim(title), body_without}

      _ ->
        {fallback_slug |> String.replace("-", " ") |> String.capitalize(), body}
    end
  end
end
