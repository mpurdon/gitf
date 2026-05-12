defmodule GiTF.Knowledge.IngestTest do
  use GiTF.StoreCase

  alias GiTF.Knowledge.{Ingest, Page}

  setup do
    gitf_root =
      Path.join(System.tmp_dir!(), "knowledge-ingest-test-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(gitf_root, ".gitf"))
    File.write!(Path.join([gitf_root, ".gitf", "config.toml"]), "")

    # Source corpus we'll ingest from.
    corpus = Path.join(gitf_root, "corpus")
    File.mkdir_p!(corpus)

    prior = System.get_env("GITF_PATH")
    System.put_env("GITF_PATH", gitf_root)

    on_exit(fn ->
      if prior, do: System.put_env("GITF_PATH", prior), else: System.delete_env("GITF_PATH")
      File.rm_rf!(gitf_root)
    end)

    %{gitf_root: gitf_root, corpus: corpus}
  end

  describe "ingest_directory/3" do
    test "ingests every .md file as a page", %{corpus: corpus} do
      File.write!(Path.join(corpus, "Auth Flow.md"), "# Auth Flow\n\nDetails here.")
      File.write!(Path.join(corpus, "API Endpoints.md"), "# API Endpoints\n\nList of routes.")

      assert %{imported: 2, skipped: 0, errors: []} = Ingest.ingest_directory(corpus, "fe")

      assert %{slug: "auth-flow", title: "Auth Flow"} = Page.get("fe", "auth-flow")
      assert %{slug: "api-endpoints", title: "API Endpoints"} = Page.get("fe", "api-endpoints")
    end

    test "strips numeric prefixes from filenames", %{corpus: corpus} do
      File.write!(Path.join(corpus, "001_API Spec.md"), "# API Spec\n\nx")
      File.write!(Path.join(corpus, "017_Glossary.md"), "# Glossary\n\nx")

      assert %{imported: 2} = Ingest.ingest_directory(corpus, "fe")
      assert Page.get("fe", "api-spec")
      assert Page.get("fe", "glossary")
    end

    test "skips reserved files", %{corpus: corpus} do
      File.write!(Path.join(corpus, "Real.md"), "# Real")
      File.write!(Path.join(corpus, "_index.md"), "# Reserved")
      File.write!(Path.join(corpus, "_kanban.md"), "# Reserved")
      File.write!(Path.join(corpus, "README.md"), "# Reserved")

      assert %{imported: 1} = Ingest.ingest_directory(corpus, "fe")
      assert Page.get("fe", "real")
      refute Page.get("fe", "reserved")
    end

    test "skips reserved directories", %{corpus: corpus} do
      File.mkdir_p!(Path.join(corpus, "Templates"))
      File.write!(Path.join([corpus, "Templates", "Mission.md"]), "# Mission")

      File.mkdir_p!(Path.join(corpus, "subdir"))
      File.write!(Path.join([corpus, "subdir", "Real.md"]), "# Real")

      assert %{imported: 1} = Ingest.ingest_directory(corpus, "fe")
      assert Page.get("fe", "real")
    end

    test "recurses into non-reserved subdirectories", %{corpus: corpus} do
      File.mkdir_p!(Path.join([corpus, "auth", "deep"]))
      File.write!(Path.join([corpus, "auth", "Login.md"]), "# Login")
      File.write!(Path.join([corpus, "auth", "deep", "Token.md"]), "# Token")

      assert %{imported: 2} = Ingest.ingest_directory(corpus, "fe")
      assert Page.get("fe", "login")
      assert Page.get("fe", "token")
    end

    test "logs and skips duplicate slugs (first wins)", %{corpus: corpus} do
      File.mkdir_p!(Path.join(corpus, "a"))
      File.mkdir_p!(Path.join(corpus, "b"))
      File.write!(Path.join([corpus, "a", "Same.md"]), "# Same\n\nA body")
      File.write!(Path.join([corpus, "b", "Same.md"]), "# Same\n\nB body")

      assert %{imported: 1, skipped: 1} = Ingest.ingest_directory(corpus, "fe")
      page = Page.get("fe", "same")
      assert page != nil
    end

    test "applies an optional tag to every imported page", %{corpus: corpus} do
      File.write!(Path.join(corpus, "X.md"), "# X")

      assert %{imported: 1} = Ingest.ingest_directory(corpus, "fe", tag: "imported")
      assert Page.get("fe", "x").tags == ["imported"]
    end

    test "is idempotent — re-running replaces with latest content", %{corpus: corpus} do
      File.write!(Path.join(corpus, "X.md"), "# X\n\nv1")
      assert %{imported: 1} = Ingest.ingest_directory(corpus, "fe")

      File.write!(Path.join(corpus, "X.md"), "# X\n\nv2")
      assert %{imported: 1} = Ingest.ingest_directory(corpus, "fe")

      {:ok, body, _} = Page.read_body("fe", "x")
      assert body =~ "v2"
      assert length(Page.list("fe")) == 1
    end

    test "dry_run does not write anything", %{corpus: corpus} do
      File.write!(Path.join(corpus, "X.md"), "# X")

      assert %{imported: 1} = Ingest.ingest_directory(corpus, "fe", dry_run: true)
      assert Page.get("fe", "x") == nil
    end

    test "tolerates a non-directory input" do
      assert %{imported: 0, errors: [{_, :enotdir}]} = Ingest.ingest_directory("/no/such/dir", "fe")
    end
  end

  describe "reindex_sector/2" do
    test "no-ops when on-disk content matches the Archive", %{corpus: _corpus} do
      {:ok, _} = Page.put(%{slug: "x", sector_id: "fe", body: "v1"})
      assert %{rescanned: 1, updated: 0, missing: 0} = Ingest.reindex_sector("fe")
    end

    test "rebuilds the index when an operator edits a page externally", %{gitf_root: root} do
      {:ok, _} = Page.put(%{slug: "x", sector_id: "fe", body: "v1"})

      file = Path.join([root, "vault", "Sectors", "fe", "Pages", "x.md"])
      File.write!(file, "v2 with [[other]]")

      assert %{updated: 1, missing: 0} = Ingest.reindex_sector("fe")
      page = Page.get("fe", "x")
      assert page.links_out == ["other"]
    end

    test "tracks pages whose files have been deleted on disk", %{gitf_root: root} do
      {:ok, _} = Page.put(%{slug: "deleted", sector_id: "fe", body: "x"})

      file = Path.join([root, "vault", "Sectors", "fe", "Pages", "deleted.md"])
      File.rm!(file)

      assert %{missing: 1} = Ingest.reindex_sector("fe")
    end
  end
end
