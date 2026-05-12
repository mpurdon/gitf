defmodule GiTF.Knowledge.Index do
  @moduledoc """
  Curated table-of-contents for a sector. An index is a markdown file
  whose entries are `[[slug]]` references plus an optional gloss, so the
  ghost can scan a list without semantic search.

  ## Format

  Entries are parsed from any line shaped like one of:

      - [[slug]] — gloss text
      - [[slug]]: gloss text
      - [[slug]] gloss text
      - [[slug]]

  Section headers (`## Section Name`) are kept as content for humans but
  not currently extracted as structured grouping — that's a follow-up.

  ## Storage

  Body lives at `Sectors/<sector_id>/Indexes/<NNN>_<name>.md`. The
  `:knowledge_indexes` Archive collection caches `{name, sector_id,
  file_path, position, kind, entries, content_hash, updated_at}` so a
  ghost can retrieve the entry list without parsing the file.
  """

  require Logger

  alias GiTF.Archive
  alias GiTF.Vault.File, as: VFile
  alias GiTF.Vault.Path, as: VPath

  @collection :knowledge_indexes
  @default_kind :list

  @type entry :: %{slug: String.t(), gloss: String.t() | nil}

  @type t :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:sector_id) => String.t() | nil,
          required(:file_path) => String.t(),
          required(:position) => pos_integer(),
          required(:kind) => atom(),
          required(:entries) => [entry()],
          required(:content_hash) => String.t(),
          required(:updated_at) => DateTime.t()
        }

  # -- Public API ------------------------------------------------------------

  @doc """
  Creates or replaces an index. Required: `name`, `sector_id`, `body`.
  Optional: `position` (defaults to next available), `kind` (default `:list`).
  """
  @spec put(map()) :: {:ok, t()} | {:error, term()}
  def put(attrs) when is_map(attrs) do
    with {:ok, gitf_root} <- GiTF.gitf_dir(),
         name when is_binary(name) <- attrs[:name] || attrs["name"],
         sector_id <- attrs[:sector_id] || attrs["sector_id"],
         body <- attrs[:body] || attrs["body"] || "",
         kind <- normalize_kind(attrs[:kind] || attrs["kind"] || @default_kind),
         position <- resolve_position(sector_id, name, attrs),
         file_path <- VPath.index_file(gitf_root, sector_id, position, name),
         {:ok, content_hash} <- VFile.write(file_path, body) do
      entries = parse_entries(body)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      record =
        case get(sector_id, name) do
          nil ->
            %{
              name: name,
              sector_id: sector_id,
              file_path: file_path,
              position: position,
              kind: kind,
              entries: entries,
              content_hash: content_hash,
              updated_at: now
            }

          existing ->
            Map.merge(existing, %{
              file_path: file_path,
              position: position,
              kind: kind,
              entries: entries,
              content_hash: content_hash,
              updated_at: now
            })
        end

      upsert(record)
    else
      nil -> {:error, :missing_name}
      {:error, _} = err -> err
    end
  end

  @doc "Returns the index record for `{sector_id, name}` or nil."
  @spec get(String.t() | nil, String.t()) :: t() | nil
  def get(sector_id, name) do
    Archive.filter(@collection, fn i ->
      i[:name] == name and i[:sector_id] == sector_id
    end)
    |> List.first()
  end

  @doc "Returns all indexes for `sector_id`, sorted by position."
  @spec list(String.t() | nil) :: [t()]
  def list(sector_id) do
    Archive.filter(@collection, fn i -> i[:sector_id] == sector_id end)
    |> Enum.sort_by(& &1[:position])
  end

  @doc "Deletes an index by `{sector_id, name}`."
  @spec delete(String.t() | nil, String.t()) :: :ok
  def delete(sector_id, name) do
    case get(sector_id, name) do
      nil ->
        :ok

      idx ->
        VFile.rm(idx[:file_path]) |> ignore()
        Archive.delete(@collection, idx[:id])
        :ok
    end
  end

  @doc """
  Parses `body` and returns the structured entries. Public so the lint
  pass can re-parse without going through the Archive.

      iex> body = "## Auth\\n- [[login]] — User login flow\\n- [[logout]]: ends a session"
      iex> GiTF.Knowledge.Index.parse_entries(body)
      [
        %{slug: "login", gloss: "User login flow"},
        %{slug: "logout", gloss: "ends a session"}
      ]
  """
  @spec parse_entries(String.t()) :: [entry()]
  def parse_entries(body) when is_binary(body) do
    body
    |> String.split(~r/\r?\n/)
    |> Enum.flat_map(&parse_line/1)
    |> dedupe_by_slug()
  end

  # -- Private ---------------------------------------------------------------

  # Recognises a leading list marker, the [[slug]] reference, and an
  # optional separator + gloss. Tolerates `-`, `*`, `+`, or no marker.
  @entry_re ~r/^\s*[-*+]?\s*\[\[([^\[\]\|\n]+?)(?:\|[^\[\]\n]*?)?\]\]\s*(?:[—\-:]\s*)?(.*?)\s*$/u

  defp parse_line(line) do
    case Regex.run(@entry_re, line, capture: :all_but_first) do
      [target, gloss] ->
        slug = GiTF.Vault.Path.slugify(target)

        if slug == "" do
          []
        else
          [%{slug: slug, gloss: blank_to_nil(gloss)}]
        end

      _ ->
        []
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp dedupe_by_slug(entries) do
    {kept, _seen} =
      Enum.reduce(entries, {[], MapSet.new()}, fn e, {acc, seen} ->
        if MapSet.member?(seen, e.slug),
          do: {acc, seen},
          else: {[e | acc], MapSet.put(seen, e.slug)}
      end)

    Enum.reverse(kept)
  end

  defp upsert(record) do
    case get(record.sector_id, record.name) do
      nil -> Archive.insert(@collection, record)
      existing -> Archive.update(@collection, existing[:id], fn _ -> Map.put(record, :id, existing[:id]) end)
    end
  end

  defp resolve_position(sector_id, name, attrs) do
    case attrs[:position] || attrs["position"] do
      n when is_integer(n) and n > 0 ->
        n

      _ ->
        existing = get(sector_id, name)
        if existing, do: existing[:position], else: next_position(sector_id)
    end
  end

  defp next_position(sector_id) do
    case list(sector_id) do
      [] -> 1
      indexes -> Enum.map(indexes, & &1[:position]) |> Enum.max() |> Kernel.+(1)
    end
  end

  # Allowlist match (no String.to_atom on operator-supplied values, so
  # adversarial input can't exhaust the global atom table).
  defp normalize_kind(k) when k in [:list, :glossary, :map], do: k
  defp normalize_kind("list"), do: :list
  defp normalize_kind("glossary"), do: :glossary
  defp normalize_kind("map"), do: :map
  defp normalize_kind(_), do: @default_kind


  defp ignore(_), do: :ok
end
