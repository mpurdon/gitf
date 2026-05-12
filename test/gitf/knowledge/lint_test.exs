defmodule GiTF.Knowledge.LintTest do
  use GiTF.StoreCase

  alias GiTF.Knowledge.{Index, Lint, Page}

  setup do
    gitf_root =
      Path.join(System.tmp_dir!(), "knowledge-lint-test-#{:erlang.unique_integer([:positive])}")

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

  describe "lint/2 — orphans" do
    test "flags a page with no inbound links and not in any index" do
      {:ok, _} = Page.put(%{slug: "lonely", sector_id: "fe", title: "Lonely", body: "x"})

      assert %{orphans: [%{slug: "lonely"}]} = Lint.lint("fe")
    end

    test "does not flag a page that is referenced by another page" do
      {:ok, _} = Page.put(%{slug: "target", sector_id: "fe", title: "Target", body: "x"})
      {:ok, _} = Page.put(%{slug: "linker", sector_id: "fe", body: "see [[target]]"})

      report = Lint.lint("fe")
      slugs = Enum.map(report.orphans, & &1.slug)
      refute "target" in slugs
    end

    test "does not flag a page that appears in an index" do
      {:ok, _} = Page.put(%{slug: "indexed", sector_id: "fe", title: "Indexed", body: "x"})
      {:ok, _} = Index.put(%{name: "API", sector_id: "fe", body: "- [[indexed]]"})

      report = Lint.lint("fe")
      slugs = Enum.map(report.orphans, & &1.slug)
      refute "indexed" in slugs
    end
  end

  describe "lint/2 — broken links" do
    test "flags a forward reference to a missing page" do
      {:ok, _} = Page.put(%{slug: "src", sector_id: "fe", body: "see [[ghost]] and [[also-missing]]"})

      assert %{broken_links: broken} = Lint.lint("fe")
      pairs = Enum.map(broken, fn %{from: f, to: t} -> {f, t} end)
      assert {"src", "ghost"} in pairs
      assert {"src", "also-missing"} in pairs
    end

    test "does not flag links to existing pages" do
      {:ok, _} = Page.put(%{slug: "target", sector_id: "fe", body: "x"})
      {:ok, _} = Page.put(%{slug: "src", sector_id: "fe", body: "[[target]]"})

      assert %{broken_links: []} = Lint.lint("fe")
    end
  end

  describe "lint/2 — suggested backlinks" do
    test "suggests a backlink when title is mentioned but not linked" do
      {:ok, _} = Page.put(%{slug: "auth-flow", sector_id: "fe", title: "Auth Flow", body: "x"})

      {:ok, _} =
        Page.put(%{
          slug: "checkout",
          sector_id: "fe",
          title: "Checkout",
          body: "Uses the Auth Flow before charging."
        })

      assert %{suggested_backlinks: suggestions} = Lint.lint("fe")
      assert Enum.any?(suggestions, fn s -> s.from == "checkout" and s.to == "auth-flow" end)
    end

    test "does not suggest when the link already exists" do
      {:ok, _} = Page.put(%{slug: "auth-flow", sector_id: "fe", title: "Auth Flow", body: "x"})

      {:ok, _} =
        Page.put(%{
          slug: "checkout",
          sector_id: "fe",
          body: "Uses [[auth-flow]] before charging."
        })

      assert %{suggested_backlinks: suggestions} = Lint.lint("fe")
      refute Enum.any?(suggestions, fn s -> s.from == "checkout" and s.to == "auth-flow" end)
    end

    test "does not suggest a self-link" do
      {:ok, _} =
        Page.put(%{slug: "auth-flow", sector_id: "fe", title: "Auth Flow", body: "Auth Flow is..."})

      assert %{suggested_backlinks: suggestions} = Lint.lint("fe")
      refute Enum.any?(suggestions, fn s -> s.from == "auth-flow" and s.to == "auth-flow" end)
    end

    test "ignores titles ≤ 2 chars to avoid false positives" do
      {:ok, _} = Page.put(%{slug: "ai", sector_id: "fe", title: "AI", body: "x"})
      {:ok, _} = Page.put(%{slug: "post", sector_id: "fe", body: "Random text. Some AI mention."})

      assert %{suggested_backlinks: suggestions} = Lint.lint("fe")
      refute Enum.any?(suggestions, fn s -> s.to == "ai" end)
    end

    test "skips matches inside code blocks" do
      {:ok, _} = Page.put(%{slug: "auth-flow", sector_id: "fe", title: "Auth Flow", body: "x"})

      body = """
      Some prose about other things.

      ```elixir
      # Mentions Auth Flow inside a fenced code block.
      ```
      """

      {:ok, _} = Page.put(%{slug: "post", sector_id: "fe", body: body})

      assert %{suggested_backlinks: suggestions} = Lint.lint("fe")
      refute Enum.any?(suggestions, fn s -> s.from == "post" and s.to == "auth-flow" end)
    end

    test "respects max_suggestions cap" do
      for n <- 1..5 do
        {:ok, _} =
          Page.put(%{
            slug: "target-#{n}",
            sector_id: "fe",
            title: "Target #{n}",
            body: "x"
          })
      end

      mention_body =
        Enum.map_join(1..5, "\n", fn n -> "Discusses Target #{n}." end)

      {:ok, _} = Page.put(%{slug: "src", sector_id: "fe", body: mention_body})

      assert %{suggested_backlinks: suggestions} = Lint.lint("fe", max_suggestions: 3)
      assert length(suggestions) == 3
    end
  end

  describe "lint/2 — report shape" do
    test "includes the sector id and page count" do
      {:ok, _} = Page.put(%{slug: "a", sector_id: "fe", body: "x"})
      {:ok, _} = Page.put(%{slug: "b", sector_id: "fe", body: "x"})

      report = Lint.lint("fe")
      assert report.sector_id == "fe"
      assert report.page_count == 2
    end

    test "empty sector returns empty lists" do
      report = Lint.lint("empty")
      assert report.orphans == []
      assert report.broken_links == []
      assert report.suggested_backlinks == []
      assert report.page_count == 0
    end
  end
end
