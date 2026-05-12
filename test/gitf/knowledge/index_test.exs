defmodule GiTF.Knowledge.IndexTest do
  use GiTF.StoreCase

  alias GiTF.Knowledge.Index

  setup do
    gitf_root =
      Path.join(System.tmp_dir!(), "knowledge-index-test-#{:erlang.unique_integer([:positive])}")

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

  describe "parse_entries/1" do
    test "parses [[slug]] — gloss form" do
      assert Index.parse_entries("- [[login]] — User login flow") ==
               [%{slug: "login", gloss: "User login flow"}]
    end

    test "parses [[slug]]: gloss form" do
      assert Index.parse_entries("- [[logout]]: ends a session") ==
               [%{slug: "logout", gloss: "ends a session"}]
    end

    test "parses bare [[slug]] form (no gloss)" do
      assert Index.parse_entries("- [[refresh]]") ==
               [%{slug: "refresh", gloss: nil}]
    end

    test "tolerates *, +, or no list marker" do
      body = """
      - [[a]] — alpha
      * [[b]] — beta
      + [[c]] — gamma
      [[d]] — delta
      """

      slugs = Index.parse_entries(body) |> Enum.map(& &1.slug) |> Enum.sort()
      assert slugs == ["a", "b", "c", "d"]
    end

    test "ignores headers and prose" do
      body = """
      ## Auth
      - [[login]] — user login
      Some prose explaining things.
      ## Billing
      - [[invoices]] — invoice list
      """

      slugs = Index.parse_entries(body) |> Enum.map(& &1.slug)
      assert slugs == ["login", "invoices"]
    end

    test "normalizes [[Display Name]] → slug via Vault.Path.slugify" do
      assert [%{slug: "auth-flow"}] = Index.parse_entries("- [[Auth Flow]]")
    end

    test "deduplicates by slug, keeping first occurrence" do
      body = """
      - [[a]] — first
      - [[a]] — duplicate
      - [[b]] — second
      """

      assert Index.parse_entries(body) == [
               %{slug: "a", gloss: "first"},
               %{slug: "b", gloss: "second"}
             ]
    end

    test "ignores empty bodies" do
      assert Index.parse_entries("") == []
    end
  end

  describe "put/1 — create" do
    test "writes the index file with a numeric prefix", %{gitf_root: root} do
      assert {:ok, idx} =
               Index.put(%{
                 name: "API Endpoints",
                 sector_id: "fe",
                 body: "- [[login]] — sign in"
               })

      expected =
        Path.join([root, "vault", "Sectors", "fe", "Indexes", "001_API Endpoints.md"])

      assert idx.file_path == expected
      assert File.read!(expected) == "- [[login]] — sign in"
      assert idx.position == 1
      assert idx.kind == :list
      assert idx.entries == [%{slug: "login", gloss: "sign in"}]
    end

    test "auto-increments position when omitted" do
      {:ok, a} = Index.put(%{name: "A", sector_id: "fe", body: ""})
      {:ok, b} = Index.put(%{name: "B", sector_id: "fe", body: ""})
      {:ok, c} = Index.put(%{name: "C", sector_id: "fe", body: ""})

      assert a.position == 1
      assert b.position == 2
      assert c.position == 3
    end

    test "honours explicit position" do
      {:ok, idx} = Index.put(%{name: "Hot", sector_id: "fe", body: "", position: 99})
      assert idx.position == 99
    end

    test "indexes per sector are independent" do
      {:ok, fe} = Index.put(%{name: "Shared", sector_id: "fe", body: ""})
      {:ok, be} = Index.put(%{name: "Shared", sector_id: "be", body: ""})

      assert fe.position == 1
      assert be.position == 1
    end

    test "rejects when name is missing" do
      assert {:error, :missing_name} = Index.put(%{sector_id: "fe", body: ""})
    end

    test "honours kind option" do
      {:ok, idx} = Index.put(%{name: "Glossary", sector_id: "fe", body: "", kind: :glossary})
      assert idx.kind == :glossary

      {:ok, idx2} = Index.put(%{name: "G2", sector_id: "fe", body: "", kind: "map"})
      assert idx2.kind == :map
    end
  end

  describe "put/1 — update" do
    test "rewrites entries when the body changes" do
      {:ok, _} = Index.put(%{name: "API", sector_id: "fe", body: "- [[a]]"})
      {:ok, idx2} = Index.put(%{name: "API", sector_id: "fe", body: "- [[a]]\n- [[b]]"})

      slugs = Enum.map(idx2.entries, & &1.slug)
      assert slugs == ["a", "b"]
    end

    test "preserves the position when name is reused" do
      {:ok, _} = Index.put(%{name: "First", sector_id: "fe", body: ""})
      {:ok, _second} = Index.put(%{name: "Second", sector_id: "fe", body: ""})
      {:ok, second_v2} = Index.put(%{name: "Second", sector_id: "fe", body: "v2"})

      assert second_v2.position == 2
    end
  end

  describe "list/1" do
    test "returns indexes sorted by position" do
      {:ok, _} = Index.put(%{name: "B", sector_id: "fe", body: "", position: 5})
      {:ok, _} = Index.put(%{name: "A", sector_id: "fe", body: "", position: 1})
      {:ok, _} = Index.put(%{name: "C", sector_id: "fe", body: "", position: 3})

      names = Index.list("fe") |> Enum.map(& &1.name)
      assert names == ["A", "C", "B"]
    end
  end

  describe "delete/2" do
    test "removes the file and the index record" do
      {:ok, idx} = Index.put(%{name: "Doomed", sector_id: "fe", body: "x"})
      assert File.exists?(idx.file_path)

      :ok = Index.delete("fe", "Doomed")
      refute File.exists?(idx.file_path)
      assert Index.get("fe", "Doomed") == nil
    end

    test "is a no-op when the index doesn't exist" do
      assert :ok = Index.delete("fe", "ghost")
    end
  end

  describe "Retrieval.index_of/2" do
    test "returns the index by name" do
      {:ok, idx} = Index.put(%{name: "API", sector_id: "fe", body: "- [[a]]"})

      assert %{name: "API"} = GiTF.Knowledge.Retrieval.index_of("fe", "API")
      assert idx.entries == [%{slug: "a", gloss: nil}]
    end
  end
end
