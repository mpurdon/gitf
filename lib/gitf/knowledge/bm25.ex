defmodule GiTF.Knowledge.BM25 do
  @moduledoc """
  Okapi BM25 lexical ranking over a small in-memory corpus.

  Complements semantic (embedding) retrieval: cosine similarity captures
  meaning but underweights exact-token matches — a specific function name,
  error code, or acronym that appears verbatim in a page's title/tags. BM25
  scores those literal overlaps, and `GiTF.Knowledge.Retrieval` fuses the two
  rankings (reciprocal rank fusion) into a genuinely hybrid result.

  Standard parameters `k1 = 1.2`, `b = 0.75`.
  """

  @k1 1.2
  @b 0.75

  @doc """
  Ranks `docs` against `query`, returning `[{score, doc}]` sorted by
  descending BM25 score (zero-score docs dropped). `text_fun` extracts the
  searchable text from each doc.
  """
  @spec rank(String.t(), [term()], (term() -> String.t())) :: [{float(), term()}]
  def rank(query, docs, text_fun) when is_binary(query) and is_list(docs) do
    q_terms = query |> tokenize() |> Enum.uniq()
    corpus = Enum.map(docs, fn d -> {d, tokenize(text_fun.(d))} end)
    n = length(corpus)

    if n == 0 or q_terms == [] do
      []
    else
      avgdl = avg_doc_length(corpus, n)
      df = doc_frequencies(q_terms, corpus)

      corpus
      |> Enum.map(fn {doc, toks} -> {score_doc(q_terms, toks, df, n, avgdl), doc} end)
      |> Enum.filter(fn {s, _} -> s > 0.0 end)
      |> Enum.sort_by(fn {s, _} -> s end, :desc)
    end
  end

  @doc "Lowercase, split on non-alphanumeric, drop single-char tokens."
  @spec tokenize(String.t()) :: [String.t()]
  def tokenize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9_]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) > 1))
  end

  def tokenize(_), do: []

  # -- Internals -------------------------------------------------------------

  defp avg_doc_length(corpus, n) do
    total = corpus |> Enum.map(fn {_, toks} -> length(toks) end) |> Enum.sum()
    if n == 0, do: 0.0, else: total / n
  end

  defp doc_frequencies(q_terms, corpus) do
    Map.new(q_terms, fn t ->
      {t, Enum.count(corpus, fn {_, toks} -> t in toks end)}
    end)
  end

  defp score_doc(q_terms, toks, df, n, avgdl) do
    dl = length(toks)
    tf = Enum.frequencies(toks)

    Enum.reduce(q_terms, 0.0, fn t, acc ->
      f = Map.get(tf, t, 0)

      if f == 0 do
        acc
      else
        dft = Map.get(df, t, 0)
        idf = :math.log((n - dft + 0.5) / (dft + 0.5) + 1.0)
        norm = if avgdl > 0, do: dl / avgdl, else: 0.0
        acc + idf * (f * (@k1 + 1)) / (f + @k1 * (1 - @b + @b * norm))
      end
    end)
  end
end
