defmodule GiTF.Skills.Retrieval do
  @moduledoc """
  Retrieves the top-K skills most relevant to an op, across global and
  sector-scoped candidates.

  Flow:

    1. Build a query text from the op (title + description + goal).
    2. Embed the query via `GiTF.Skills.Embedding`.
    3. Pull the candidate pool (`Skills.candidates_for/1`).
    4. Ensure each candidate has an embedding (lazy-embed on first use).
    5. Cosine top-K against the query.
    6. Apply min-similarity threshold.

  On a factory with no embedding provider (the claude-CLI subscription
  box has no API key at all, and the CLI cannot embed), steps 2–6 are
  replaced by BM25 over name + description + body: exact-token
  overlap — a function name, a command, a file — is a decent proxy
  for "this skill is about this op", and a library that can only be
  applied when someone pays for embeddings is a library that is never
  applied. The same fallback covers an embedding call that fails.

  Config knobs (with defaults):

    * `:skill_top_k` — default 5
    * `:skill_min_similarity` — default 0.45
    * `:skill_embedding_model` — default `"openai:text-embedding-3-small"`
  """

  require Logger

  alias GiTF.Skills
  alias GiTF.Skills.Embedding

  @doc """
  Returns a list of skills ranked by relevance to the op, truncated to
  top-K with min-similarity filtering applied.

  `op` should have `:title` and `:description` (strings). `sector_id` may
  be `nil` for global-only retrieval.

  Options:
    * `:top_k` — override the configured top-K
    * `:min_similarity` — override the configured threshold

  Returns `{:ok, [skill]}` on success. Any failure (embedding error,
  no candidates, etc.) returns `{:ok, []}` — retrieval is best-effort
  and must never block ghost provisioning.
  """
  @spec retrieve(map(), String.t() | nil, keyword()) :: {:ok, [Skills.t()]}
  def retrieve(op, sector_id, opts \\ []) do
    top_k = Keyword.get(opts, :top_k, config(:skill_top_k, 5))
    min_sim = Keyword.get(opts, :min_similarity, config(:skill_min_similarity, 0.45))
    model = Embedding.default_model()

    query = build_query_text(op)

    case Skills.candidates_for(sector_id) do
      [] ->
        {:ok, []}

      candidates ->
        if Embedding.available?() do
          with {:ok, query_vec} <- Embedding.embed(model, query),
               prepared <- ensure_embeddings(candidates, model) do
            ranked =
              Embedding.top_k(query_vec, prepared, & &1.embedding, top_k)
              |> Enum.filter(fn {score, _} -> score >= min_sim end)
              |> Enum.map(fn {_score, skill} -> skill end)

            {:ok, ranked}
          else
            {:error, reason} ->
              Logger.warning(
                "Skills.Retrieval: embedding failed (#{inspect(reason)}); ranking lexically"
              )

              {:ok, lexical(query, candidates, top_k)}
          end
        else
          {:ok, lexical(query, candidates, top_k)}
        end
    end
  rescue
    e ->
      Logger.warning("Skills.Retrieval raised: #{Exception.message(e)}")
      {:ok, []}
  end

  # -- Private -----------------------------------------------------------------

  # Function words carry no "aboutness"; on a corpus of a few dozen skills
  # they would otherwise match everything to everything.
  @stopwords ~w(the a an and or of to in on for with by from at as is are be
    was were this that these those it its into over after before when then
    than not no do does did done use using used via)

  @doc false
  def lexical(query, candidates, top_k) do
    query =
      query
      |> GiTF.Knowledge.BM25.tokenize()
      |> Enum.reject(&(&1 in @stopwords))
      |> Enum.join(" ")

    GiTF.Knowledge.BM25.rank(query, candidates, &"#{&1.name}\n#{&1.description}\n#{&1.body}")
    |> Enum.take(top_k)
    |> Enum.map(fn {_score, skill} -> skill end)
  end

  # Lazy-embeds skills whose `embedding` is nil or was produced by a
  # different model. Persists the embedding back to the Archive so future
  # retrievals skip the embed call.
  defp ensure_embeddings(skills, model) do
    Enum.map(skills, fn skill ->
      case skill do
        %{embedding: vec, embedding_model: ^model} when is_list(vec) ->
          skill

        _ ->
          case embed_body(skill, model) do
            {:ok, vec} ->
              persist_embedding(skill.id, vec, model)
              Map.merge(skill, %{embedding: vec, embedding_model: model})

            {:error, _} ->
              # Keep the skill in the pool but with no embedding —
              # top_k will skip it via the extract-fn.
              Map.put(skill, :embedding, nil)
          end
      end
    end)
  end

  defp embed_body(skill, model) do
    text = "#{skill.name}\n#{skill.description}\n#{skill.body}"
    Embedding.embed(model, text)
  end

  defp persist_embedding(id, vec, model) do
    Skills.update(id, fn s ->
      Map.merge(s, %{embedding: vec, embedding_model: model})
    end)
  rescue
    e ->
      Logger.warning(
        "Skills.Retrieval: persist_embedding for #{id} failed: #{Exception.message(e)}"
      )

      :ok
  end

  defp build_query_text(op) do
    title = Map.get(op, :title, "") || ""
    description = Map.get(op, :description, "") || ""
    goal = Map.get(op, :goal_restatement, "") || Map.get(op, :goal, "") || ""

    [title, description, goal]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp config(key, default) do
    Application.get_env(:gitf, key, default)
  end
end
