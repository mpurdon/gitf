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
  @protected_re ~r/```[\s\S]*?```|`[^`\n]+`/

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

  @doc """
  Rewrites `[[old_slug]]` and `[[old_slug|alias]]` references in `body`
  to point at `new_slug`. Respects code fences and inline backticks the
  same way `parse_wikilinks/1` does — links inside ``` blocks or
  `inline code` are left untouched.

  Used by `GiTF.Knowledge.Rename` to propagate slug renames through
  backlinking pages.
  """
  @spec rewrite_target(String.t(), String.t(), String.t()) :: String.t()
  def rewrite_target(body, old_slug, new_slug)
      when is_binary(body) and is_binary(old_slug) and is_binary(new_slug) do
    rewrite_re = ~r/\[\[#{Regex.escape(old_slug)}(\|[^\]\n]*)?\]\]/

    body
    |> split_protected()
    |> Enum.map_join("", fn
      {:prose, chunk} ->
        Regex.replace(rewrite_re, chunk, fn _full, alias_part ->
          "[[#{new_slug}#{alias_part || ""}]]"
        end)

      {:protected, chunk} ->
        chunk
    end)
  end

  # Replace fenced code blocks and inline-code spans with whitespace so
  # offsets line up but the content is invisible to the link regex.
  defp strip_code_regions(body) do
    String.replace(body, @protected_re, fn match ->
      String.duplicate(" ", String.length(match))
    end)
  end

  # Splits the body into alternating prose / protected regions
  # (code fences + inline backticks) preserving content so the caller
  # can rewrite only inside prose.
  defp split_protected(body) do
    @protected_re
    |> Regex.split(body, include_captures: true, trim: false)
    |> Enum.map(fn chunk ->
      if Regex.match?(@protected_re, chunk),
        do: {:protected, chunk},
        else: {:prose, chunk}
    end)
  end
end
