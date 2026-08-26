defmodule GiTF.Knowledge.RetrievalTest do
  use GiTF.StoreCase

  alias GiTF.Knowledge.Page
  alias GiTF.Knowledge.Retrieval

  defmodule MockClient do
    @behaviour GiTF.Skills.Embedding

    @impl true
    def embed(_model, text) do
      keywords = ["auth", "billing", "search", "deploy"]
      down = String.downcase(text)
      vec = for kw <- keywords, do: if(String.contains?(down, kw), do: 1.0, else: 0.0)
      vec = if Enum.all?(vec, &(&1 == 0.0)), do: [0.001, 0.001, 0.001, 0.001], else: vec
      {:ok, vec}
    end
  end

  setup do
    gitf_root =
      Path.join(
        System.tmp_dir!(),
        "knowledge-retrieval-test-#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(gitf_root, ".gitf"))
    File.write!(Path.join([gitf_root, ".gitf", "config.toml"]), "")

    prior_path = System.get_env("GITF_PATH")
    System.put_env("GITF_PATH", gitf_root)

    prior_client = Application.get_env(:gitf, :embedding_client)
    Application.put_env(:gitf, :embedding_client, MockClient)

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

  describe "get_by_slug/2" do
    test "returns the page when it exists" do
      {:ok, _} = Page.put(%{slug: "auth-flow", sector_id: "fe", body: "Auth"})
      assert %{slug: "auth-flow"} = Retrieval.get_by_slug("fe", "auth-flow")
    end

    test "returns nil for an unknown slug" do
      assert Retrieval.get_by_slug("fe", "nope") == nil
    end
  end

  describe "links/3" do
    setup do
      {:ok, _} = Page.put(%{slug: "a", sector_id: "fe", body: "A links to [[b]] and [[c]]"})
      {:ok, _} = Page.put(%{slug: "b", sector_id: "fe", body: "B links to [[a]]"})
      {:ok, _} = Page.put(%{slug: "c", sector_id: "fe", body: "C"})
      :ok
    end

    test "returns outbound links by default direction :both" do
      slugs =
        Retrieval.links("fe", "a")
        |> Enum.map(& &1.slug)
        |> Enum.sort()

      # a's links_out: [b, c]; links_in: [b]; both = [b, c]
      assert slugs == ["b", "c"]
    end

    test "direction: :out returns only outbound" do
      slugs =
        Retrieval.links("fe", "a", direction: :out)
        |> Enum.map(& &1.slug)
        |> Enum.sort()

      assert slugs == ["b", "c"]
    end

    test "direction: :in returns only inbound" do
      slugs = Retrieval.links("fe", "a", direction: :in) |> Enum.map(& &1.slug)
      assert slugs == ["b"]
    end

    test "skips dangling references silently" do
      {:ok, _} = Page.put(%{slug: "x", sector_id: "fe", body: "[[ghost]]"})
      assert Retrieval.links("fe", "x", direction: :out) == []
    end

    test "returns [] for a missing source page" do
      assert Retrieval.links("fe", "missing") == []
    end
  end

  describe "search/3" do
    setup do
      {:ok, _} =
        Page.put(%{slug: "auth-flow", sector_id: "fe", title: "Auth", body: "auth login session"})

      {:ok, _} =
        Page.put(%{
          slug: "billing-overview",
          sector_id: "fe",
          title: "Billing",
          body: "billing invoices"
        })

      {:ok, _} =
        Page.put(%{
          slug: "search-ranking",
          sector_id: "fe",
          title: "Search",
          body: "search ranking"
        })

      :ok
    end

    test "ranks the most-relevant page first" do
      assert {:ok, results} =
               Retrieval.search("fe", "what does the auth flow look like?",
                 top_k: 1,
                 min_similarity: 0.0
               )

      assert length(results) == 1
      [{_score, page}] = results
      assert page.slug == "auth-flow"
    end

    test "returns multiple results when top_k > 1" do
      assert {:ok, results} =
               Retrieval.search("fe", "auth and billing concerns", top_k: 3, min_similarity: 0.0)

      slugs = Enum.map(results, fn {_, p} -> p.slug end) |> Enum.sort()
      assert "auth-flow" in slugs
      assert "billing-overview" in slugs
    end

    test "filters below the min_similarity threshold" do
      assert {:ok, []} =
               Retrieval.search("fe", "totally unrelated nonsense words",
                 top_k: 5,
                 min_similarity: 0.99
               )
    end

    test "persists embeddings on first call so subsequent calls skip the embed step" do
      assert {:ok, _} = Retrieval.search("fe", "auth", top_k: 1, min_similarity: 0.0)

      # All pages should now have embeddings populated.
      pages = Page.list("fe")
      assert Enum.all?(pages, fn p -> is_list(p[:embedding]) end)
    end

    test "include_global=true mixes in nil-sector pages" do
      {:ok, _} =
        Page.put(%{
          slug: "global-style",
          sector_id: nil,
          title: "Global",
          body: "auth styling guide"
        })

      assert {:ok, results} =
               Retrieval.search("fe", "auth", top_k: 5, min_similarity: 0.0, include_global: true)

      slugs = Enum.map(results, fn {_, p} -> p.slug end)
      assert "global-style" in slugs
    end

    test "include_global=false excludes nil-sector pages" do
      {:ok, _} =
        Page.put(%{
          slug: "global-style",
          sector_id: nil,
          title: "Global",
          body: "auth styling guide"
        })

      assert {:ok, results} =
               Retrieval.search("fe", "auth",
                 top_k: 5,
                 min_similarity: 0.0,
                 include_global: false
               )

      slugs = Enum.map(results, fn {_, p} -> p.slug end)
      refute "global-style" in slugs
    end

    test "returns {:ok, []} when no candidates exist" do
      assert {:ok, []} = Retrieval.search("empty-sector", "anything", top_k: 5)
    end
  end
end
