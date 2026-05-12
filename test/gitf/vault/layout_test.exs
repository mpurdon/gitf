defmodule GiTF.Vault.LayoutTest do
  use ExUnit.Case, async: true

  alias GiTF.Vault.Layout

  setup do
    root = Path.join(System.tmp_dir!(), "vault-layout-test-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  describe "init_vault/1" do
    test "creates the global scaffold", %{root: root} do
      :ok = Layout.init_vault(root)

      assert File.exists?(Path.join(root, "vault/README.md"))
      assert File.dir?(Path.join(root, "vault/Daily Notes"))
      assert File.dir?(Path.join(root, "vault/Ghosts"))
      assert File.dir?(Path.join(root, "vault/Sectors/_global/Pages"))
      assert File.dir?(Path.join(root, "vault/Templates"))
    end

    test "seeds template files", %{root: root} do
      :ok = Layout.init_vault(root)

      templates = Path.join(root, "vault/Templates")
      assert File.exists?(Path.join(templates, "Daily Note.md"))
      assert File.exists?(Path.join(templates, "Mission.md"))
      assert File.exists?(Path.join(templates, "Page.md"))
      assert File.exists?(Path.join(templates, "Ghost Profile.md"))
      assert File.exists?(Path.join(templates, "Sector Index.md"))
      assert File.exists?(Path.join(templates, "Index.md"))
    end

    test "is idempotent — does not overwrite existing files", %{root: root} do
      :ok = Layout.init_vault(root)

      readme_path = Path.join(root, "vault/README.md")
      File.write!(readme_path, "operator-edited content")

      :ok = Layout.init_vault(root)
      assert File.read!(readme_path) == "operator-edited content"
    end
  end

  describe "init_sector/2" do
    test "creates the sector folder structure", %{root: root} do
      :ok = Layout.init_sector(root, %{id: "frontend", name: "Frontend"})

      sector = Path.join(root, "vault/Sectors/frontend")
      assert File.exists?(Path.join(sector, "001_index.md"))
      assert File.exists?(Path.join(sector, "002_kanban.md"))
      assert File.dir?(Path.join(sector, "Pages"))
      assert File.dir?(Path.join(sector, "Indexes"))
      assert File.dir?(Path.join(sector, "Missions"))
    end

    test "001_index.md uses the sector name in the H1", %{root: root} do
      :ok = Layout.init_sector(root, %{id: "be", name: "API Server"})

      body = File.read!(Path.join(root, "vault/Sectors/be/001_index.md"))
      assert body =~ "# API Server"
      assert body =~ "sector_id: be"
    end

    test "002_kanban.md is a valid Obsidian Kanban file", %{root: root} do
      :ok = Layout.init_sector(root, %{id: "fe", name: "Frontend"})

      body = File.read!(Path.join(root, "vault/Sectors/fe/002_kanban.md"))
      assert body =~ "kanban-plugin: basic"
      assert body =~ "## Todo"
      assert body =~ "## Doing"
      assert body =~ "## Review"
      assert body =~ "## Done"
    end

    test "is idempotent — does not overwrite operator-edited index", %{root: root} do
      :ok = Layout.init_sector(root, %{id: "fe", name: "Frontend"})
      index_path = Path.join(root, "vault/Sectors/fe/001_index.md")
      File.write!(index_path, "operator-edited")

      :ok = Layout.init_sector(root, %{id: "fe", name: "Frontend"})
      assert File.read!(index_path) == "operator-edited"
    end

    test "tolerates missing sector id (no-op)", %{root: root} do
      :ok = Layout.init_sector(root, %{})
      refute File.dir?(Path.join(root, "vault/Sectors"))
    end

    test "implicitly initializes the global vault scaffold", %{root: root} do
      :ok = Layout.init_sector(root, %{id: "fe", name: "Frontend"})
      assert File.exists?(Path.join(root, "vault/README.md"))
    end
  end
end
