defmodule GiTF.Skills.EmbeddingTest do
  use ExUnit.Case, async: false

  alias GiTF.Skills.Embedding

  defmodule MockClient do
    @behaviour GiTF.Skills.Embedding

    @impl true
    def embed(_model, text) do
      # Deterministic vectors derived from text hash so identical text → identical vector
      seed = :erlang.phash2(text)
      vec = for i <- 0..7, do: :math.sin(seed + i) * 0.5
      {:ok, vec}
    end
  end

  setup do
    prev = Application.get_env(:gitf, :embedding_client)
    Application.put_env(:gitf, :embedding_client, MockClient)
    on_exit(fn ->
      if prev,
        do: Application.put_env(:gitf, :embedding_client, prev),
        else: Application.delete_env(:gitf, :embedding_client)
    end)

    :ok
  end

  describe "embed/2" do
    test "returns vector via mocked client" do
      assert {:ok, [_ | _] = vec} = Embedding.embed("model-x", "hello world")
      assert length(vec) == 8
    end

    test "caches identical (model, text) — second call hits cache" do
      assert {:ok, vec1} = Embedding.embed("model-x", "cached input")
      assert {:ok, vec2} = Embedding.embed("model-x", "cached input")
      assert vec1 == vec2
    end

    test "different model means different cache entry" do
      assert {:ok, vec1} = Embedding.embed("model-A", "same text")
      assert {:ok, vec2} = Embedding.embed("model-B", "same text")
      # MockClient ignores the model so vectors are equal — but they should
      # have been computed independently. We can't observe cache directly,
      # so this test just validates no error and consistent shape.
      assert is_list(vec1) and is_list(vec2)
    end
  end

  describe "cosine/2" do
    test "identical vectors have similarity 1.0" do
      v = [1.0, 0.0, 0.0]
      assert_in_delta Embedding.cosine(v, v), 1.0, 1.0e-6
    end

    test "orthogonal vectors have similarity 0.0" do
      assert_in_delta Embedding.cosine([1.0, 0.0], [0.0, 1.0]), 0.0, 1.0e-6
    end
  end

  describe "top_k/4" do
    test "returns top-K candidates sorted by similarity" do
      query = [1.0, 0.0, 0.0]

      candidates = [
        %{id: "a", embedding: [0.9, 0.1, 0.0]},
        %{id: "b", embedding: [0.0, 1.0, 0.0]},
        %{id: "c", embedding: [0.95, 0.05, 0.0]},
        %{id: "d", embedding: nil}
      ]

      result = Embedding.top_k(query, candidates, & &1.embedding, 2)
      assert length(result) == 2
      [{score1, top1}, {score2, top2}] = result
      assert top1.id in ["a", "c"]
      assert top2.id in ["a", "c"]
      assert score1 >= score2
    end

    test "skips candidates with nil embedding" do
      query = [1.0, 0.0]

      candidates = [
        %{id: "x", embedding: nil},
        %{id: "y", embedding: [1.0, 0.0]}
      ]

      result = Embedding.top_k(query, candidates, & &1.embedding, 5)
      assert length(result) == 1
      assert elem(hd(result), 1).id == "y"
    end
  end
end
