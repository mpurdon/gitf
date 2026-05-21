defmodule GiTF.Knowledge.RenameTest do
  use GiTF.StoreCase

  alias GiTF.Knowledge.{Page, Rename}
  alias GiTF.Vault.Path, as: VPath

  setup do
    gitf_root =
      Path.join(System.tmp_dir!(), "rename-test-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(gitf_root, ".gitf"))
    File.write!(Path.join([gitf_root, ".gitf", "config.toml"]), "")

    prior_path = System.get_env("GITF_PATH")
    System.put_env("GITF_PATH", gitf_root)

    on_exit(fn ->
      if prior_path,
        do: System.put_env("GITF_PATH", prior_path),
        else: System.delete_env("GITF_PATH")

      File.rm_rf!(gitf_root)
    end)

    %{gitf_root: gitf_root, sector: "renametest"}
  end

  describe "detect/1" do
    test "matches a missing file to an orphan with the same hash", %{sector: sector} do
      {:ok, _} = Page.put(%{slug: "old-slug", sector_id: sector, body: "# Old\n\nbody"})

      # Simulate a plain `mv` rename on disk
      old_page = Page.get(sector, "old-slug")
      new_path = Path.join(Path.dirname(old_page.file_path), "new-slug.md")
      File.rename!(old_page.file_path, new_path)

      detection = Rename.detect(sector)

      assert [rename] = detection.renames
      assert rename.old_slug == "old-slug"
      assert rename.new_slug == "new-slug"
      assert rename.new_file_path == new_path
      assert detection.hash_drift == []
      assert detection.ambiguous == []
    end

    test "flags hash_drift when the file is gone and no orphan matches", %{sector: sector} do
      {:ok, _} = Page.put(%{slug: "lost", sector_id: sector, body: "# Lost\n"})
      old_page = Page.get(sector, "lost")
      File.rm!(old_page.file_path)

      detection = Rename.detect(sector)

      assert detection.renames == []
      assert "lost" in detection.hash_drift
    end

    test "flags ambiguous when two orphans share the same hash as a missing page",
         %{sector: sector} do
      {:ok, _} = Page.put(%{slug: "ambig", sector_id: sector, body: "# Ambig\n\nidentical"})
      old_page = Page.get(sector, "ambig")
      dir = Path.dirname(old_page.file_path)

      File.rename!(old_page.file_path, Path.join(dir, "twin-a.md"))
      File.write!(Path.join(dir, "twin-b.md"), File.read!(Path.join(dir, "twin-a.md")))

      detection = Rename.detect(sector)

      assert detection.renames == []
      assert [{"ambig", paths}] = detection.ambiguous
      assert length(paths) == 2
    end

    test "returns nothing when everything is in sync", %{sector: sector} do
      {:ok, _} = Page.put(%{slug: "stable", sector_id: sector, body: "# Stable\n"})
      detection = Rename.detect(sector)

      assert detection.renames == []
      assert detection.hash_drift == []
      assert detection.ambiguous == []
    end
  end

  describe "rescan/2 — plain-mv rename (links not auto-rewritten)" do
    test "updates the index and rewrites [[old]] in linking pages", %{sector: sector} do
      {:ok, _} = Page.put(%{slug: "target", sector_id: sector, body: "# Target\n\nthe target"})
      {:ok, _} = Page.put(%{slug: "linker", sector_id: sector, body: "See [[target]] for more."})

      # `mv target.md → renamed.md` without rewriting wikilinks
      target = Page.get(sector, "target")
      new_path = Path.join(Path.dirname(target.file_path), "renamed.md")
      File.rename!(target.file_path, new_path)

      result = Rename.rescan(sector)

      assert [%{old_slug: "target", new_slug: "renamed"}] = result.renames
      assert result.backlinks_rewritten == 1
      assert result.errors == []

      # Index now keys on the new slug
      assert Page.get(sector, "target") == nil
      assert renamed = Page.get(sector, "renamed")
      assert renamed.slug == "renamed"

      # The linker page's body was rewritten on disk
      {:ok, linker_body, _hash} = Page.read_body(sector, "linker")
      assert linker_body =~ "[[renamed]]"
      refute linker_body =~ "[[target]]"

      # And the index agrees
      linker = Page.get(sector, "linker")
      assert "renamed" in linker.links_out
      refute "target" in linker.links_out
    end

    test "is idempotent — second rescan does nothing", %{sector: sector} do
      {:ok, _} = Page.put(%{slug: "t", sector_id: sector, body: "# T\n"})
      {:ok, _} = Page.put(%{slug: "src", sector_id: sector, body: "Ref [[t]]"})

      target = Page.get(sector, "t")
      new_path = Path.join(Path.dirname(target.file_path), "renamed.md")
      File.rename!(target.file_path, new_path)

      first = Rename.rescan(sector)
      second = Rename.rescan(sector)

      assert length(first.renames) == 1
      assert second.renames == []
      assert second.backlinks_rewritten == 0
    end
  end

  describe "rescan/2 — Obsidian-style rename (links pre-rewritten)" do
    test "skips backlink rewrites but refreshes the index", %{sector: sector} do
      {:ok, _} = Page.put(%{slug: "doc", sector_id: sector, body: "# Doc\n"})
      {:ok, _} = Page.put(%{slug: "ref", sector_id: sector, body: "See [[doc]]"})

      # Simulate Obsidian's rename: file moved + linking page's body
      # already updated to [[doc-v2]]
      doc = Page.get(sector, "doc")
      new_path = Path.join(Path.dirname(doc.file_path), "doc-v2.md")
      File.rename!(doc.file_path, new_path)

      ref = Page.get(sector, "ref")
      File.write!(ref.file_path, "See [[doc-v2]]")

      result = Rename.rescan(sector)

      assert [%{old_slug: "doc", new_slug: "doc-v2"}] = result.renames
      # No body rewrite needed — Obsidian already did it
      assert result.backlinks_rewritten == 0

      # Index now reflects the new slug in links_out
      ref_after = Page.get(sector, "ref")
      assert "doc-v2" in ref_after.links_out
      refute "doc" in ref_after.links_out
    end
  end

  describe "rescan/2 — dry_run" do
    test "detects but does not mutate", %{sector: sector} do
      {:ok, _} = Page.put(%{slug: "p", sector_id: sector, body: "# P\n"})
      page = Page.get(sector, "p")
      new_path = Path.join(Path.dirname(page.file_path), "q.md")
      File.rename!(page.file_path, new_path)

      result = Rename.rescan(sector, dry_run: true)

      assert [_] = result.renames
      assert result.backlinks_rewritten == 0
      # Index untouched
      assert Page.get(sector, "p") != nil
      assert Page.get(sector, "q") == nil
    end
  end

  # Suppress warning if VPath ends up unused in this file's evolution
  _ = VPath
end
