defmodule GiTF.Knowledge.Lint do
  @moduledoc """
  Structural health checks over a sector's wiki.

  Three issue classes detected without an LLM call:

    * **Orphans** — pages with no inbound wikilinks AND not referenced
      from any index. They exist but nothing points at them, so a
      ghost browsing the indexes will never find them.
    * **Broken links** — outbound `[[slug]]` references whose target
      doesn't exist. Often forward references made when an entity was
      renamed or anticipated but never created.
    * **Suggested backlinks** — body of page A mentions the title of
      page B (case-insensitive whole-word match) but doesn't link to
      it. Cheap, deterministic, often actionable.

  Contradiction detection and rich rewrites are LLM-driven and live in
  `GiTF.Knowledge.Lint.Reviewer` (M3 follow-up; not implemented yet).

  ## Usage

      iex> GiTF.Knowledge.Lint.lint("frontend")
      %{
        orphans: [%{slug: "..."}, ...],
        broken_links: [%{from: "...", to: "..."}, ...],
        suggested_backlinks: [%{from: "...", to: "...", term: "..."}, ...]
      }

  Pure with respect to the wiki — does not modify pages. Operators (or
  a future auto-fix policy) decide what to do with the report.
  """

  alias GiTF.Knowledge.Index
  alias GiTF.Knowledge.Page

  @type orphan :: %{slug: String.t(), title: String.t()}
  @type broken :: %{from: String.t(), to: String.t()}
  @type suggested :: %{from: String.t(), to: String.t(), term: String.t()}

  @type report :: %{
          sector_id: String.t() | nil,
          page_count: non_neg_integer(),
          orphans: [orphan()],
          broken_links: [broken()],
          suggested_backlinks: [suggested()]
        }

  @doc """
  Runs all structural lints for `sector_id` and returns a report.

  Options:
    * `:max_suggestions` — cap the suggested-backlinks list (default 50)
  """
  @spec lint(String.t() | nil, keyword()) :: report()
  def lint(sector_id, opts \\ []) do
    pages = Page.list(sector_id)
    indexes = Index.list(sector_id)

    page_slugs = MapSet.new(pages, & &1.slug)
    index_slugs = MapSet.new(Enum.flat_map(indexes, fn idx -> Enum.map(idx.entries || [], & &1.slug) end))

    %{
      sector_id: sector_id,
      page_count: length(pages),
      orphans: detect_orphans(pages, index_slugs),
      broken_links: detect_broken(pages, page_slugs),
      suggested_backlinks: detect_suggestions(pages, opts)
    }
  end

  # -- Detectors -------------------------------------------------------------

  defp detect_orphans(pages, index_slugs) do
    pages
    |> Enum.filter(fn p ->
      (p[:links_in] || []) == [] and not MapSet.member?(index_slugs, p.slug)
    end)
    |> Enum.map(fn p -> %{slug: p.slug, title: p.title} end)
    |> Enum.sort_by(& &1.slug)
  end

  defp detect_broken(pages, page_slugs) do
    pages
    |> Enum.flat_map(fn p ->
      (p[:links_out] || [])
      |> Enum.reject(&MapSet.member?(page_slugs, &1))
      |> Enum.map(fn target -> %{from: p.slug, to: target} end)
    end)
    |> Enum.sort_by(fn %{from: f, to: t} -> {f, t} end)
  end

  defp detect_suggestions(pages, opts) do
    max = Keyword.get(opts, :max_suggestions, 50)

    # Pre-compute compiled per-page title patterns. Word-boundary, case
    # insensitive, ignores titles ≤ 2 chars (too noisy).
    title_index =
      pages
      |> Enum.filter(&(byte_size(&1.title || "") > 2))
      |> Enum.map(fn p ->
        pattern = ~r/\b#{Regex.escape(p.title)}\b/i
        {p.slug, p.title, pattern}
      end)

    bodies = read_bodies(pages)

    pages
    |> Enum.flat_map(fn page ->
      body = Map.get(bodies, page.slug, "")
      stripped = strip_links_and_code(body)

      already_links_to = MapSet.new(page[:links_out] || [])

      title_index
      |> Enum.reject(fn {target_slug, _, _} ->
        target_slug == page.slug or MapSet.member?(already_links_to, target_slug)
      end)
      |> Enum.flat_map(fn {target_slug, target_title, pattern} ->
        if Regex.match?(pattern, stripped) do
          [%{from: page.slug, to: target_slug, term: target_title}]
        else
          []
        end
      end)
    end)
    |> Enum.uniq_by(fn s -> {s.from, s.to} end)
    |> Enum.sort_by(fn s -> {s.from, s.to} end)
    |> Enum.take(max)
  end

  # -- Helpers ---------------------------------------------------------------

  defp read_bodies(pages) do
    pages
    |> Task.async_stream(
      fn p ->
        case Page.read_body(p[:sector_id], p.slug) do
          {:ok, body, _} -> {p.slug, body}
          _ -> :skip
        end
      end,
      max_concurrency: System.schedulers_online(),
      timeout: 5_000,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.reduce(%{}, fn
      {:ok, {slug, body}}, acc -> Map.put(acc, slug, body)
      _, acc -> acc
    end)
  end

  # Removes existing wikilinks and code regions so they don't trigger
  # false-positive suggestions (a `[[Auth Flow]]` link shouldn't suggest
  # backlinking to the same target).
  defp strip_links_and_code(body) do
    body
    |> String.replace(~r/```[\s\S]*?```/, " ")
    |> String.replace(~r/`[^`\n]+`/, " ")
    |> String.replace(~r/\[\[[^\]]+\]\]/, " ")
  end
end
