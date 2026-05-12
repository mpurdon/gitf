defmodule GiTF.Knowledge.PageTest do
  use GiTF.StoreCase

  alias GiTF.Knowledge.Page

  setup do
    gitf_root =
      Path.join(System.tmp_dir!(), "gitf-page-test-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(gitf_root, ".gitf"))
    File.write!(Path.join([gitf_root, ".gitf", "config.toml"]), "")

    prior = System.get_env("GITF_PATH")
    System.put_env("GITF_PATH", gitf_root)

    on_exit(fn ->
      if prior, do: System.put_env("GITF_PATH", prior), else: System.delete_env("GITF_PATH")
      File.rm_rf!(gitf_root)
    end)

    %{gitf_root: gitf_root}
  end

  describe "put/1 — single page" do
    test "writes the body to disk under Sectors/<id>/Pages/<slug>.md", %{gitf_root: root} do
      assert {:ok, page} =
               Page.put(%{
                 slug: "auth-flow",
                 sector_id: "frontend",
                 title: "Auth Flow",
                 body: "# Auth Flow\n\nDetails."
               })

      expected_path = Path.join([root, "vault", "Sectors", "frontend", "Pages", "auth-flow.md"])
      assert page.file_path == expected_path
      assert File.read!(expected_path) == "# Auth Flow\n\nDetails."
      assert page.content_hash == GiTF.Vault.File.content_hash("# Auth Flow\n\nDetails.")
    end

    test "indexes the page by {sector_id, slug}" do
      assert {:ok, _} = Page.put(%{slug: "x", sector_id: "fe", body: "x"})
      assert %{slug: "x"} = Page.get("fe", "x")
    end

    test "derives title from H1 when not provided" do
      assert {:ok, page} =
               Page.put(%{slug: "thing", sector_id: "fe", body: "# Real Title\n\nbody"})

      assert page.title == "Real Title"
    end

    test "falls back to slug-derived title when H1 absent" do
      assert {:ok, page} = Page.put(%{slug: "no-heading", sector_id: "fe", body: "no heading"})
      assert page.title == "No heading"
    end

    test "derives slug from title when slug missing" do
      assert {:ok, page} = Page.put(%{title: "Some Page", sector_id: "fe", body: ""})
      assert page.slug == "some-page"
    end

    test "rejects when neither slug nor title provided" do
      assert {:error, :missing_slug} = Page.put(%{body: "x"})
    end

    test "stores normalized tags as a unique list of strings" do
      assert {:ok, page} =
               Page.put(%{
                 slug: "p",
                 sector_id: "fe",
                 body: "x",
                 tags: ["impl", :impl, "auth"]
               })

      assert Enum.sort(page.tags) == ["auth", "impl"]
    end

    test "global pages live under _global/Pages", %{gitf_root: root} do
      assert {:ok, page} = Page.put(%{slug: "design-principles", sector_id: nil, body: "d"})

      expected = Path.join([root, "vault", "Sectors", "_global", "Pages", "design-principles.md"])
      assert page.file_path == expected
      assert File.exists?(expected)
    end
  end

  describe "put/1 — updates" do
    test "rewrites the body and recomputes the hash" do
      assert {:ok, p1} = Page.put(%{slug: "x", sector_id: "fe", body: "v1"})
      assert {:ok, p2} = Page.put(%{slug: "x", sector_id: "fe", body: "v2"})

      assert p1.id == p2.id
      assert p1.content_hash != p2.content_hash
      assert File.read!(p2.file_path) == "v2"
    end

    test "invalidates the embedding when the body changes" do
      assert {:ok, p1} = Page.put(%{slug: "x", sector_id: "fe", body: "v1"})

      # Simulate an embedding having been written by retrieval
      {:ok, _} =
        GiTF.Archive.update(:knowledge_pages, p1.id, fn r ->
          Map.merge(r, %{embedding: [0.1, 0.2], embedding_model: "test"})
        end)

      assert %{embedding: [0.1, 0.2]} = Page.get("fe", "x")

      assert {:ok, p2} = Page.put(%{slug: "x", sector_id: "fe", body: "v2"})
      assert p2.embedding == nil
      assert p2.embedding_model == nil
    end

    test "preserves the embedding when the body is identical" do
      assert {:ok, p1} = Page.put(%{slug: "x", sector_id: "fe", body: "same"})

      {:ok, _} =
        GiTF.Archive.update(:knowledge_pages, p1.id, fn r ->
          Map.merge(r, %{embedding: [0.5], embedding_model: "test"})
        end)

      assert {:ok, p2} = Page.put(%{slug: "x", sector_id: "fe", body: "same"})
      assert p2.embedding == [0.5]
      assert p2.embedding_model == "test"
    end
  end

  describe "backlinks" do
    test "creating page A → B writes B's links_in to include A" do
      assert {:ok, _b} = Page.put(%{slug: "b", sector_id: "fe", body: "B"})
      assert {:ok, a} = Page.put(%{slug: "a", sector_id: "fe", body: "see [[b]]"})

      assert a.links_out == ["b"]

      b = Page.get("fe", "b")
      assert b.links_in == ["a"]
    end

    test "removing the [[b]] reference from A removes A from B.links_in" do
      assert {:ok, _b} = Page.put(%{slug: "b", sector_id: "fe", body: "B"})
      assert {:ok, _a} = Page.put(%{slug: "a", sector_id: "fe", body: "see [[b]]"})

      assert Page.get("fe", "b").links_in == ["a"]

      assert {:ok, _a2} = Page.put(%{slug: "a", sector_id: "fe", body: "no link now"})

      assert Page.get("fe", "b").links_in == []
    end

    test "deleting A removes A from every page's links_in" do
      assert {:ok, _b} = Page.put(%{slug: "b", sector_id: "fe", body: "B"})
      assert {:ok, _c} = Page.put(%{slug: "c", sector_id: "fe", body: "C"})
      assert {:ok, _a} = Page.put(%{slug: "a", sector_id: "fe", body: "[[b]] and [[c]]"})

      assert Page.get("fe", "b").links_in == ["a"]
      assert Page.get("fe", "c").links_in == ["a"]

      assert :ok = Page.delete("fe", "a")
      assert Page.get("fe", "b").links_in == []
      assert Page.get("fe", "c").links_in == []
    end

    test "forward references (target page doesn't exist yet) don't crash" do
      assert {:ok, a} = Page.put(%{slug: "a", sector_id: "fe", body: "[[unknown]]"})
      assert a.links_out == ["unknown"]
      # No page created for "unknown" — that's lint's job to flag.
      assert Page.get("fe", "unknown") == nil
    end

    test "multiple inbound links accumulate without duplication" do
      assert {:ok, _b} = Page.put(%{slug: "b", sector_id: "fe", body: "B"})
      assert {:ok, _a1} = Page.put(%{slug: "a1", sector_id: "fe", body: "[[b]]"})
      assert {:ok, _a2} = Page.put(%{slug: "a2", sector_id: "fe", body: "[[b]]"})
      # Re-put a1 — should not duplicate
      assert {:ok, _a1b} = Page.put(%{slug: "a1", sector_id: "fe", body: "[[b]] again"})

      assert Enum.sort(Page.get("fe", "b").links_in) == ["a1", "a2"]
    end
  end

  describe "delete/2" do
    test "removes the file and the index record" do
      assert {:ok, p} = Page.put(%{slug: "x", sector_id: "fe", body: "x"})
      assert File.exists?(p.file_path)

      assert :ok = Page.delete("fe", "x")
      refute File.exists?(p.file_path)
      assert Page.get("fe", "x") == nil
    end

    test "is a no-op when the page doesn't exist" do
      assert :ok = Page.delete("fe", "nonexistent")
    end
  end

  describe "list/1" do
    test "returns only pages in the given sector" do
      {:ok, _} = Page.put(%{slug: "a", sector_id: "fe", body: "a"})
      {:ok, _} = Page.put(%{slug: "b", sector_id: "fe", body: "b"})
      {:ok, _} = Page.put(%{slug: "c", sector_id: "be", body: "c"})

      slugs = Page.list("fe") |> Enum.map(& &1.slug) |> Enum.sort()
      assert slugs == ["a", "b"]
    end

    test "returns global pages when sector_id is nil" do
      {:ok, _} = Page.put(%{slug: "g", sector_id: nil, body: "g"})
      {:ok, _} = Page.put(%{slug: "f", sector_id: "fe", body: "f"})

      assert [%{slug: "g"}] = Page.list(nil)
    end
  end

  describe "reindex/2" do
    test "rebuilds the record from disk after an external edit" do
      assert {:ok, p1} = Page.put(%{slug: "x", sector_id: "fe", body: "v1"})

      # Simulate operator editing the file directly in Obsidian.
      File.write!(p1.file_path, "v2 with [[other]]")

      # Index still has the old hash and no link to "other".
      stale = Page.get("fe", "x")
      assert stale.content_hash == p1.content_hash
      assert stale.links_out == []

      assert {:ok, fresh} = Page.reindex("fe", "x")
      assert fresh.content_hash == GiTF.Vault.File.content_hash("v2 with [[other]]")
      assert fresh.links_out == ["other"]
    end
  end

  describe "read_body/2" do
    test "returns body and disk hash" do
      {:ok, p} = Page.put(%{slug: "x", sector_id: "fe", body: "hello"})
      assert {:ok, "hello", hash} = Page.read_body("fe", "x")
      assert hash == p.content_hash
    end

    test "returns :enoent when the file is missing" do
      assert {:error, :enoent} = Page.read_body("fe", "absent")
    end
  end
end
