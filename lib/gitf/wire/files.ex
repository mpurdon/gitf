defmodule GiTF.Wire.Files do
  @moduledoc """
  The file table of a Wire document: `F<n> path` declarations and the
  resolution of `F<n>` references (or bare paths) back to paths.

  Paths are the most expensive tokens an artifact carries — a path like
  `src-tauri/src/models.rs` costs 7–9 tokens every time it is written — so
  a document declares each path once and every artifact block cites the
  id. A prompt that embeds several artifacts shares one table across all
  of them; the model's reply may cite that table and may extend it with
  new declarations, numbered after the last one it was shown.
  """

  @type t :: %{pos_integer() => String.t()}

  @spec new() :: t()
  def new, do: %{}

  @doc "Builds a table from an ordered list of paths."
  @spec from_paths([String.t()]) :: t()
  def from_paths(paths), do: new() |> refs(paths) |> elem(0)

  @doc "Adds every path (idempotent), returning `{table, refs}` in input order."
  @spec refs(t(), [String.t()]) :: {t(), [String.t()]}
  def refs(table, paths) do
    paths
    |> Enum.filter(&is_binary/1)
    |> Enum.map_reduce(table, fn path, table ->
      path = String.trim(path)

      case Enum.find(table, fn {_n, p} -> p == path end) do
        {n, _} ->
          {"F#{n}", table}

        nil ->
          n = next_id(table)
          {"F#{n}", Map.put(table, n, path)}
      end
    end)
    |> then(fn {refs, table} -> {table, refs} end)
  end

  @doc """
  Absorbs the `F<n> path` declarations found in parsed records. A
  declaration reusing a known id overrides it — the document is closer to
  the truth than the context it was decoded in.
  """
  @spec absorb(t(), [map()]) :: t()
  def absorb(table, records),
    do: Enum.reduce(declarations(records), table, fn r, t -> Map.put(t, r.id, r.text) end)

  @doc "Paths declared in the records, in id order."
  @spec declared([map()]) :: [String.t()]
  def declared(records),
    do: records |> declarations() |> Enum.sort_by(& &1.id) |> Enum.map(& &1.text) |> Enum.uniq()

  defp declarations(records) do
    for %{tag: "F", id: id, text: text} <- records,
        is_integer(id),
        is_binary(text),
        do: %{id: id, text: String.trim(text)}
  end

  @doc """
  Resolves one token: `F3` → its path, a bare path → itself (trimmed),
  `-`/nil → nil. An unknown `F` id resolves to nil rather than raising.
  """
  @spec resolve(t(), String.t() | nil) :: String.t() | nil
  def resolve(_table, token) when token in [nil, "-"], do: nil

  def resolve(table, token) do
    case Regex.run(~r/^F(\d+)$/, token) do
      [_, n] -> Map.get(table, String.to_integer(n))
      nil -> String.trim(token)
    end
  end

  @doc "Resolves a comma list of tokens (`F1,F3,src/new.ts`) to paths."
  @spec resolve_list(t(), String.t() | nil) :: [String.t()]
  def resolve_list(table, list),
    do: list |> split_list() |> Enum.map(&resolve(table, &1)) |> Enum.reject(&is_nil/1)

  @doc ~S|Splits a comma id list: `"a,b"` → `["a", "b"]`; `"-"` and nil → `[]`.|
  @spec split_list(String.t() | nil) :: [String.t()]
  def split_list(list) when list in [nil, "-"], do: []
  def split_list(list), do: String.split(list, ",", trim: true)

  @doc "Renders the table as `F<n> path` lines (empty string when empty)."
  @spec render(t()) :: String.t()
  def render(table) when map_size(table) == 0, do: ""

  def render(table) do
    table
    |> Enum.sort()
    |> Enum.map_join("\n", fn {n, path} -> "F#{n} #{path}" end)
    |> Kernel.<>("\n")
  end

  defp next_id(table), do: Enum.max(Map.keys(table), fn -> 0 end) + 1
end
