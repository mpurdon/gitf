defmodule GiTF.Knowledge.Retrieval do
  @moduledoc """
  Hybrid retrieval over the wiki: direct, graph, semantic.

  Three modes, all returning `t:GiTF.Knowledge.Page.t/0` records:

    * `get_by_slug/2` — direct lookup. Free, deterministic, citeable.
    * `links/3` — outbound or inbound graph traversal. Free.
    * `search/3` — cosine top-K over per-page embeddings. Lazy-embeds
      pages whose embedding is nil or stale. Mirrors
      `GiTF.Skills.Retrieval` and reuses `GiTF.Skills.Embedding` to avoid
      a parallel embedding stack.

  Configuration:

    * `:knowledge_top_k` — default 5
    * `:knowledge_min_similarity` — default 0.4

  Failures (embedding errors, transient issues) are logged and downgraded
  to `{:ok, []}` — knowledge retrieval is best-effort and must never
  block ghost provisioning.
  """

  require Logger

  alias GiTF.Archive
  alias GiTF.Knowledge.Index
  alias GiTF.Knowledge.Page
  alias GiTF.Skills.Embedding

  # -- Direct lookup ---------------------------------------------------------

  @doc """
  Returns the page record for `{sector_id, slug}` or `nil`.
  """
  @spec get_by_slug(String.t() | nil, String.t()) :: Page.t() | nil
  def get_by_slug(sector_id, slug), do: Page.get(sector_id, slug)

  # -- Graph traversal -------------------------------------------------------

  @doc """
  Returns the pages linked from (or to) the page at `{sector_id, slug}`.

    * `direction: :out` — pages this page points to
    * `direction: :in`  — pages that point at this page
    * `direction: :both` (default) — both, deduped

  Targets that don't (yet) exist as pages are skipped silently — those are
  forward references / dangling links and surface in the lint pass.
  """
  @spec links(String.t() | nil, String.t(), keyword()) :: [Page.t()]
  def links(sector_id, slug, opts \\ []) do
    direction = Keyword.get(opts, :direction, :both)

    case Page.get(sector_id, slug) do
      nil ->
        []

      page ->
        slugs =
          case direction do
            :out -> page[:links_out] || []
            :in -> page[:links_in] || []
            :both -> Enum.uniq((page[:links_out] || []) ++ (page[:links_in] || []))
          end

        slugs
        |> Enum.flat_map(fn s ->
          case Page.get(sector_id, s) do
            nil -> []
            target -> [target]
          end
        end)
    end
  end

  # -- Index lookup ----------------------------------------------------------

  @doc """
  Returns the index named `name` for `sector_id`, or `nil`. Free,
  deterministic — useful when a ghost knows there's a curated TOC and
  wants the entry list without semantic search.
  """
  @spec index_of(String.t() | nil, String.t()) :: Index.t() | nil
  def index_of(sector_id, name), do: Index.get(sector_id, name)

  @doc "Lists all indexes in `sector_id` sorted by position."
  @spec indexes(String.t() | nil) :: [Index.t()]
  def indexes(sector_id), do: Index.list(sector_id)

  # -- Semantic search -------------------------------------------------------

  @doc """
  Returns up to `top_k` pages ranked by cosine similarity to `query`.

  `sector_id` may be `nil` for global-only retrieval. Pass `:any` to
  search across all sectors (operator-driven cross-sector lookup).

  Options:
    * `:top_k` — override the configured top-K
    * `:min_similarity` — override the configured threshold
    * `:include_global` — when searching a sector, also include `sector_id: nil`
      pages (default `true`)

  Returns `{:ok, [{score, page}]}` so callers can inspect or threshold
  scores. On any failure returns `{:ok, []}`.
  """
  @spec search(String.t() | nil | :any, String.t(), keyword()) ::
          {:ok, [{float(), Page.t()}]}
  def search(sector_id, query, opts \\ []) when is_binary(query) do
    top_k = Keyword.get(opts, :top_k, config(:knowledge_top_k, 5))
    min_sim = Keyword.get(opts, :min_similarity, config(:knowledge_min_similarity, 0.4))
    include_global = Keyword.get(opts, :include_global, true)
    model = Embedding.default_model()

    case candidates(sector_id, include_global) do
      [] ->
        {:ok, []}

      candidates ->
        with {:ok, query_vec} <- Embedding.embed(model, query),
             prepared <- ensure_embeddings(candidates, model) do
          semantic =
            Embedding.top_k(query_vec, prepared, & &1[:embedding], length(prepared))
            |> Enum.filter(fn {score, _} -> score >= min_sim end)

          lexical =
            GiTF.Knowledge.BM25.rank(query, prepared, &page_lexical_text/1)

          ranked = fuse(semantic, lexical, top_k)
          {:ok, ranked}
        else
          {:error, reason} ->
            Logger.warning(
              "Knowledge.Retrieval: embedding failed (#{inspect(reason)}); returning no results"
            )

            {:ok, []}
        end
    end
  rescue
    e ->
      Logger.warning("Knowledge.Retrieval raised: #{Exception.message(e)}")
      {:ok, []}
  end

  # -- Internals -------------------------------------------------------------

  # Reciprocal Rank Fusion of the semantic and lexical rankings. RRF is
  # parameter-light and robust to the two scorers being on different scales
  # (cosine ∈ [-1,1] vs unbounded BM25): a page's fused score is the sum of
  # 1/(k + rank) across whichever rankings it appears in. The returned score
  # is the page's best semantic similarity (for callers/telemetry that
  # threshold on it), falling back to the RRF score when it's lexical-only.
  @rrf_k 60

  defp fuse(semantic, lexical, top_k) do
    sem_scores = Map.new(semantic, fn {score, page} -> {page[:id], score} end)

    rrf =
      %{}
      |> add_rrf(semantic)
      |> add_rrf(lexical)

    pages_by_id =
      (semantic ++ lexical)
      |> Map.new(fn {_score, page} -> {page[:id], page} end)

    rrf
    |> Enum.sort_by(fn {_id, rrf_score} -> rrf_score end, :desc)
    |> Enum.take(top_k)
    |> Enum.map(fn {id, rrf_score} ->
      page = Map.fetch!(pages_by_id, id)
      display_score = Map.get(sem_scores, id, rrf_score)
      {display_score, page}
    end)
  end

  defp add_rrf(acc, ranking) do
    ranking
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {{_score, page}, rank}, m ->
      Map.update(m, page[:id], 1.0 / (@rrf_k + rank), &(&1 + 1.0 / (@rrf_k + rank)))
    end)
  end

  # Cheap lexical text: title + tags + humanised slug. Deliberately avoids a
  # disk read of the body on the hot path — the body is already represented
  # semantically by the embedding; BM25 here adds the exact-token signal
  # (function names, acronyms, error codes) that lives in titles/tags.
  defp page_lexical_text(page) do
    slug_words = (page[:slug] || "") |> String.replace(["-", "_", "/"], " ")
    tags = (page[:tags] || []) |> Enum.join(" ")
    "#{page[:title]} #{tags} #{slug_words}"
  end

  defp candidates(:any, _include_global) do
    Archive.all(:knowledge_pages)
  end

  defp candidates(nil, _include_global) do
    Page.list(nil)
  end

  defp candidates(sector_id, true) when is_binary(sector_id) do
    Page.list(sector_id) ++ Page.list(nil)
  end

  defp candidates(sector_id, false) when is_binary(sector_id) do
    Page.list(sector_id)
  end

  # Lazy-embeds pages whose `embedding` is nil or was produced by a
  # different model. Persists the embedding back so future retrievals
  # skip the embed call. Pattern mirrors `GiTF.Skills.Retrieval`.
  #
  # Stale pages run in parallel — first cold search after a content
  # edit may need to embed many pages, and serialising HTTP calls
  # made the search-path latency proportional to N×provider_rtt.
  defp ensure_embeddings(pages, model) do
    {fresh, stale} =
      Enum.split_with(pages, fn
        %{embedding: vec, embedding_model: ^model} when is_list(vec) -> true
        _ -> false
      end)

    embedded =
      stale
      |> Task.async_stream(
        fn page ->
          case embed_page(page, model) do
            {:ok, vec} ->
              persist_embedding(page[:id], vec, model)
              Map.merge(page, %{embedding: vec, embedding_model: model})

            {:error, _} ->
              Map.put(page, :embedding, nil)
          end
        end,
        max_concurrency: embed_concurrency(),
        timeout: 30_000,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.flat_map(fn
        {:ok, page} -> [page]
        _ -> []
      end)

    fresh ++ embedded
  end

  defp embed_concurrency do
    Application.get_env(:gitf, :knowledge_embed_concurrency, 8)
  end

  defp embed_page(page, model) do
    case Page.read_body(page[:sector_id], page[:slug]) do
      {:ok, body, _hash} ->
        text = "#{page[:title]}\n\n#{body}"
        Embedding.embed(model, text)

      {:error, _} = err ->
        err
    end
  end

  defp persist_embedding(id, vec, model) do
    Archive.update(:knowledge_pages, id, fn p ->
      Map.merge(p, %{embedding: vec, embedding_model: model})
    end)
  rescue
    e ->
      Logger.warning(
        "Knowledge.Retrieval: persist_embedding for #{id} failed: #{Exception.message(e)}"
      )

      :ok
  end

  defp config(key, default), do: Application.get_env(:gitf, key, default)
end
