defmodule GiTF.Knowledge.Link do
  @moduledoc """
  Wikilink parsing and slug normalization.

  Pages link to each other with Obsidian-style `[[slug]]` or
  `[[slug|alias]]` syntax. This module is the only place that knows how
  to extract those references. The `:knowledge_pages` index uses the
  result to maintain `links_out` and the reciprocal `links_in` on
  referenced pages.

  Code-fenced and inline-code regions are skipped — `[[brackets]]` inside
  ``` fences ``` or `inline backticks` are treated as content, not links.
  """

  @link_re ~r/\[\[([^\[\]\|\n]+?)(?:\|[^\[\]\n]*?)?\]\]/

  @doc """
  Parses `body` and returns the unique, normalized slugs referenced via
  `[[slug]]` or `[[slug|alias]]`. Order is the order of first appearance.

  Slugs are normalized identically to `GiTF.Vault.Path.slugify/1` so a
  page authored with `[[Auth Flow]]` resolves to the same target as
  `[[auth-flow]]`.

      iex> GiTF.Knowledge.Link.parse_wikilinks("see [[Auth Flow]] and [[api-endpoints|the API doc]]")
      ["auth-flow", "api-endpoints"]
  """
  @spec parse_wikilinks(String.t()) :: [String.t()]
  def parse_wikilinks(body) when is_binary(body) do
    body
    |> strip_code_regions()
    |> then(&Regex.scan(@link_re, &1, capture: :all_but_first))
    |> Enum.map(fn [target] -> GiTF.Vault.Path.slugify(target) end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  # Replace fenced code blocks and inline-code spans with whitespace so
  # offsets line up but the content is invisible to the link regex.
  defp strip_code_regions(body) do
    body
    |> String.replace(~r/```[\s\S]*?```/, fn match ->
      String.duplicate(" ", String.length(match))
    end)
    |> String.replace(~r/`[^`\n]+`/, fn match ->
      String.duplicate(" ", String.length(match))
    end)
  end
end
