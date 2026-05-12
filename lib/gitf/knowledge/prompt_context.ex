defmodule GiTF.Knowledge.PromptContext do
  @moduledoc """
  Builds a knowledge-aware prompt context block for phase ghosts.

  The wiki gives ghosts something `Intel.PromptContext` doesn't: pre-
  compiled, deterministic, citeable knowledge. This module surfaces:

    * The sector's curated indexes (Karpathy-style TOCs) — one line each.
    * The top-K semantically-relevant pages for the mission's goal —
      with title and a one-line gloss extracted from the page body.

  Returned as a markdown string, capped at `:knowledge_context_max_chars`
  (default 6000 chars ≈ 1500 tokens) to fit the locked design budget.
  Returns `""` when knowledge context is disabled, the sector has no
  pages, or anything fails — knowledge injection is best-effort and
  must never block ghost provisioning.
  """

  require Logger

  alias GiTF.Knowledge.Index
  alias GiTF.Knowledge.Page
  alias GiTF.Knowledge.Retrieval

  @default_max_chars 6_000
  @default_top_k 3

  @doc """
  Builds the knowledge block for `sector_id`, scoped to the mission's
  goal.

  Options:
    * `:top_k` — number of semantic-relevance pages to include (default 3)
    * `:max_chars` — total cap (default 6000 ≈ 1500 tokens)

  Returns `""` when there's nothing useful to say.
  """
  @spec for_mission(String.t() | nil, map(), keyword()) :: String.t()
  def for_mission(sector_id, mission, opts \\ [])
  def for_mission(nil, _mission, _opts), do: ""

  def for_mission(sector_id, mission, opts) when is_map(mission) do
    if enabled?() do
      max_chars = Keyword.get(opts, :max_chars, config(:knowledge_context_max_chars, @default_max_chars))
      top_k = Keyword.get(opts, :top_k, config(:knowledge_top_k_for_prompt, @default_top_k))

      query = build_query(mission)
      indexes = Index.list(sector_id)
      pages = relevant_pages(sector_id, query, top_k)

      if indexes == [] and pages == [] do
        ""
      else
        render(indexes, pages)
        |> truncate(max_chars)
      end
    else
      ""
    end
  rescue
    e ->
      Logger.warning("Knowledge.PromptContext raised: #{Exception.message(e)}")
      ""
  end

  @doc """
  Same as `for_mission/3` but for a specific phase. Currently the phase
  doesn't change the output; reserved for M3 phase-tailored views (e.g.,
  research gets more breadth, implementation gets the most-cited pages).
  """
  @spec for_phase(String.t() | nil, String.t(), map(), keyword()) :: String.t()
  def for_phase(sector_id, _phase, mission, opts \\ []) do
    for_mission(sector_id, mission, opts)
  end

  # -- Internals -------------------------------------------------------------

  defp build_query(m) do
    [m[:goal], m[:name]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp relevant_pages(_sector_id, "", _top_k), do: []

  defp relevant_pages(sector_id, query, top_k) do
    case Retrieval.search(sector_id, query, top_k: top_k, min_similarity: 0.0) do
      {:ok, results} ->
        results
        |> Enum.map(fn {_score, page} -> page end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp render(indexes, pages) do
    sections =
      [
        render_indexes(indexes),
        render_pages(pages)
      ]
      |> Enum.reject(&(&1 == ""))

    if sections == [] do
      ""
    else
      header = "## Knowledge\n\nPre-compiled wiki for this sector. Read any page via its file under `Sectors/<sector>/Pages/<slug>.md`."

      ([header | sections] ++ [""])
      |> Enum.intersperse("\n\n")
      |> IO.iodata_to_binary()
      |> String.trim_trailing()
    end
  end

  defp render_indexes([]), do: ""

  defp render_indexes(indexes) do
    lines =
      indexes
      |> Enum.sort_by(& &1.position)
      |> Enum.map(fn idx ->
        count = length(idx.entries || [])
        "- [[#{Path.basename(idx.file_path, ".md")}]] · #{count} entr#{if count == 1, do: "y", else: "ies"}"
      end)

    "### Indexes\n\n" <> Enum.join(lines, "\n")
  end

  defp render_pages([]), do: ""

  defp render_pages(pages) do
    lines =
      pages
      |> Enum.map(fn p ->
        gloss = first_sentence(p)
        gloss_part = if gloss == "", do: "", else: " — #{gloss}"
        "- [[#{p.slug}]] (#{p.title})#{gloss_part}"
      end)

    "### Likely-relevant pages\n\n" <> Enum.join(lines, "\n")
  end

  # First non-heading, non-blank sentence from the page body. Used as a
  # one-line gloss in the prompt — keeps the context dense without
  # requiring operators to maintain a separate "summary" field.
  defp first_sentence(%{sector_id: sector, slug: slug}) do
    case Page.read_body(sector, slug) do
      {:ok, body, _hash} ->
        body
        |> String.split(~r/\r?\n/)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(fn line ->
          line == "" or String.starts_with?(line, "#") or String.starts_with?(line, "---")
        end)
        |> List.first()
        |> case do
          nil -> ""
          line -> line |> String.split(~r/[\.\!\?](\s|$)/, parts: 2) |> List.first() |> short(120)
        end

      _ ->
        ""
    end
  end

  defp first_sentence(_), do: ""

  defp short(s, n) when byte_size(s) <= n, do: s
  defp short(s, n), do: String.slice(s, 0, n) <> "…"

  defp truncate(s, max) when byte_size(s) <= max, do: s
  defp truncate(s, max), do: String.slice(s, 0, max) <> "\n\n_(truncated)_"

  defp enabled? do
    Application.get_env(:gitf, :knowledge_context_enabled, false) == true
  end

  defp config(key, default), do: Application.get_env(:gitf, key, default)
end
