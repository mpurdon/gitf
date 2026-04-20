defmodule GiTF.Skills.Embedding do
  @moduledoc """
  Embedding client for skill retrieval. Thin wrapper over `ReqLLM.embed/3`
  with an ETS cache to avoid re-embedding identical text.

  Mockable via `Application.get_env(:gitf, :embedding_client, Default)` so
  the simulator and unit tests can supply deterministic vectors without an
  LLM call.

      config :gitf, :embedding_client, GiTF.Skills.Embedding.Mock

  Provider/model is configured via `:skill_embedding_model` (default
  `"openai:text-embedding-3-small"` — well-supported by ReqLLM, ~$0.02/M tokens).
  """

  @type vector :: [float()]

  @callback embed(model :: String.t(), text :: String.t()) ::
              {:ok, vector()} | {:error, term()}

  @cache_table :gitf_skills_embedding_cache

  # -- Public API --------------------------------------------------------------

  @doc "Returns the configured embedding client module."
  @spec impl() :: module()
  def impl do
    Application.get_env(:gitf, :embedding_client, __MODULE__.Default)
  end

  @doc """
  Embeds text using the configured model. Cached: identical (model, text)
  pairs return the cached vector without a second LLM call.
  """
  @spec embed(String.t()) :: {:ok, vector()} | {:error, term()}
  def embed(text) when is_binary(text) do
    embed(default_model(), text)
  end

  @spec embed(String.t(), String.t()) :: {:ok, vector()} | {:error, term()}
  def embed(model, text) when is_binary(model) and is_binary(text) do
    key = cache_key(model, text)

    case cache_lookup(key) do
      {:ok, vec} ->
        {:ok, vec}

      :miss ->
        case impl().embed(model, text) do
          {:ok, vec} = ok ->
            cache_put(key, vec)
            ok

          {:error, _} = err ->
            err
        end
    end
  end

  @doc """
  Cosine similarity between two vectors. Delegates to ReqLLM, which has
  identical-length validation and zero-vector handling built in.
  """
  @spec cosine(vector(), vector()) :: float()
  def cosine(a, b) when is_list(a) and is_list(b) do
    ReqLLM.cosine_similarity(a, b)
  end

  @doc """
  Returns the top-K candidates ranked by cosine similarity to `query_vec`.
  Each candidate is `{score, item}` so callers can apply a min-similarity
  threshold before truncating.

  `extract_vec_fn` pulls the embedding from each candidate (e.g.,
  `& &1.embedding`). Candidates with `nil` embedding are skipped.
  """
  @spec top_k(vector(), [item], (item -> nil | vector()), pos_integer()) ::
          [{float(), item}]
        when item: var
  def top_k(query_vec, candidates, extract_vec_fn, k)
      when is_list(query_vec) and is_list(candidates) and is_function(extract_vec_fn, 1) and
             is_integer(k) and k > 0 do
    candidates
    |> Enum.flat_map(fn item ->
      case extract_vec_fn.(item) do
        nil -> []
        vec when is_list(vec) -> [{cosine(query_vec, vec), item}]
        _ -> []
      end
    end)
    |> Enum.sort_by(fn {score, _} -> score end, :desc)
    |> Enum.take(k)
  end

  @doc "Returns the configured default embedding model spec."
  @spec default_model() :: String.t()
  def default_model do
    Application.get_env(:gitf, :skill_embedding_model, "openai:text-embedding-3-small")
  end

  # -- Cache (ETS, lazily created) ---------------------------------------------

  defp cache_lookup(key) do
    ensure_cache()

    case :ets.lookup(@cache_table, key) do
      [{^key, vec}] -> {:ok, vec}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp cache_put(key, vec) do
    ensure_cache()
    :ets.insert(@cache_table, {key, vec})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp cache_key(model, text), do: {model, :erlang.phash2(text)}

  # Race-safe lazy table creation. If two processes race here, one will
  # win :ets.new and the other will rescue ArgumentError and proceed.
  defp ensure_cache do
    case :ets.whereis(@cache_table) do
      :undefined ->
        try do
          :ets.new(@cache_table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end
end

defmodule GiTF.Skills.Embedding.Default do
  @moduledoc false
  @behaviour GiTF.Skills.Embedding

  @impl true
  def embed(model, text) do
    case ReqLLM.embed(model, text) do
      {:ok, vec} when is_list(vec) ->
        # Single-text returns flat [float, ...]; defend against accidental
        # batch return shape just in case a provider behaves differently.
        case vec do
          [head | _] when is_list(head) -> {:ok, head}
          _ -> {:ok, vec}
        end

      {:error, _} = err ->
        err

      other ->
        {:error, {:unexpected_embed_result, other}}
    end
  end
end
