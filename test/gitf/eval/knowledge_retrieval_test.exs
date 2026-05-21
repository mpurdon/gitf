defmodule GiTF.Eval.KnowledgeRetrievalTest do
  use GiTF.StoreCase

  alias GiTF.Eval.KnowledgeRetrieval

  # Deterministic embedding stub. Vectors are 8-D:
  #
  #   * Axes 0-5: topic keywords (auth, session, otp, genserver,
  #     telemetry, ecto). Set when the text contains the keyword.
  #   * Axes 6-7: off-topic markers (pizza, dinner). Set only by
  #     off-topic test queries; no seeded page contains these words.
  #
  # Texts that hit no axis at all (e.g., the password-hashing page
  # body) fall back to a uniform low vector over the topic axes so
  # cosine is well-defined but orthogonal to both topic queries and
  # off-topic queries — below the 0.4 default threshold either way.
  defmodule TopicVectorClient do
    @behaviour GiTF.Skills.Embedding

    @topic_keywords ~w(auth session otp genserver telemetry ecto)
    @off_topic_markers ~w(pizza dinner)

    @impl true
    def embed(_model, text) do
      down = String.downcase(text)

      topic = for kw <- @topic_keywords, do: if(String.contains?(down, kw), do: 1.0, else: 0.0)
      off = for kw <- @off_topic_markers, do: if(String.contains?(down, kw), do: 1.0, else: 0.0)
      vec = topic ++ off

      vec =
        if Enum.all?(vec, &(&1 == 0.0)) do
          # Background page with no recognised topic — uniform low
          # vector keeps cosine defined but well below threshold.
          [0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.0, 0.0]
        else
          vec
        end

      {:ok, vec}
    end
  end

  setup do
    gitf_root =
      Path.join(System.tmp_dir!(), "kreval-test-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(gitf_root, ".gitf"))
    File.write!(Path.join([gitf_root, ".gitf", "config.toml"]), "")

    prior_path = System.get_env("GITF_PATH")
    System.put_env("GITF_PATH", gitf_root)

    prior_client = Application.get_env(:gitf, :embedding_client)
    Application.put_env(:gitf, :embedding_client, TopicVectorClient)

    on_exit(fn ->
      if prior_path,
        do: System.put_env("GITF_PATH", prior_path),
        else: System.delete_env("GITF_PATH")

      if prior_client,
        do: Application.put_env(:gitf, :embedding_client, prior_client),
        else: Application.delete_env(:gitf, :embedding_client)

      File.rm_rf!(gitf_root)
    end)

    %{gitf_root: gitf_root}
  end

  describe "metadata" do
    test "name + description are stable strings" do
      assert KnowledgeRetrieval.name() == "knowledge_retrieval"
      assert KnowledgeRetrieval.description() =~ "Knowledge"
    end

    test "cases/0 returns the documented case shape" do
      cases = KnowledgeRetrieval.cases()
      assert is_list(cases) and length(cases) >= 5

      Enum.each(cases, fn c ->
        assert is_binary(c.id)
        assert is_binary(c.query)
        assert c.expected_slug == :none or is_binary(c.expected_slug)
        assert is_integer(c.min_rank)
      end)
    end
  end

  describe "run/2 — positive cases" do
    test "passes when the expected slug ranks within min_rank" do
      result =
        KnowledgeRetrieval.run(
          %{
            id: "auth_t",
            query: "authentication overview",
            expected_slug: "authentication-overview",
            min_rank: 3
          },
          []
        )

      assert {:pass, meta} = result
      assert meta.rank in 1..3
      assert "authentication-overview" in meta.top_k
    end

    test "fails when the expected slug is below min_rank" do
      # Query hits the `ecto` topic axis so the slug surfaces, but
      # min_rank: 0 is impossible (ranks are 1-indexed).
      result =
        KnowledgeRetrieval.run(
          %{
            id: "ecto_strict",
            query: "ecto changeset validation",
            expected_slug: "ecto-changesets",
            min_rank: 0
          },
          []
        )

      assert {:fail, meta} = result
      assert meta.reason =~ "min_rank"
    end

    test "fails when the expected slug is absent from top-K entirely" do
      result =
        KnowledgeRetrieval.run(
          %{
            id: "missing",
            query: "authentication overview",
            expected_slug: "nonexistent-page",
            min_rank: 3
          },
          []
        )

      assert {:fail, meta} = result
      assert meta.rank == nil
      assert meta.reason =~ "not in top"
    end
  end

  describe "run/2 — :none expected_slug (below-threshold rejection)" do
    test "passes when off-topic query returns no above-threshold hits" do
      result =
        KnowledgeRetrieval.run(
          %{
            id: "off_topic",
            query: "best pizza toppings for friday dinner",
            expected_slug: :none,
            min_rank: 0
          },
          []
        )

      assert {:pass, meta} = result
      assert meta.top_k == []
    end

    test "fails when an on-topic query returned matches despite :none expectation" do
      result =
        KnowledgeRetrieval.run(
          %{
            id: "false_negative",
            query: "authentication overview",
            expected_slug: :none,
            min_rank: 0
          },
          []
        )

      assert {:fail, meta} = result
      assert meta.reason =~ "off-topic"
      assert is_list(meta.top_k) and meta.top_k != []
    end
  end

  describe "corpus seeding" do
    test "is idempotent across multiple runs" do
      _ =
        KnowledgeRetrieval.run(
          %{
            id: "seed_once",
            query: "authentication",
            expected_slug: "authentication-overview",
            min_rank: 5
          },
          []
        )

      first_pages =
        GiTF.Knowledge.Page.list("_eval") |> Enum.map(& &1.slug) |> Enum.sort()

      _ =
        KnowledgeRetrieval.run(
          %{
            id: "seed_again",
            query: "otp supervision",
            expected_slug: "otp-supervision",
            min_rank: 5
          },
          []
        )

      second_pages =
        GiTF.Knowledge.Page.list("_eval") |> Enum.map(& &1.slug) |> Enum.sort()

      assert first_pages == second_pages,
             "rerunning the scenario must not duplicate / mutate the seeded pages"
    end
  end
end
