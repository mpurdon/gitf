defmodule GiTF.MedicTest do
  use ExUnit.Case, async: false

  alias GiTF.Medic
  alias GiTF.Archive

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    tmp_dir = Path.join(System.tmp_dir!(), "gitf_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Archive.start_link(data_dir: tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    :ok
  end

  describe "checks/0" do
    test "returns all check names" do
      checks = Medic.checks()
      assert is_list(checks)
      assert :git_installed in checks
      assert :model_configured in checks
      assert :database_ok in checks
      assert :settings_valid in checks
      assert :orphan_shells in checks
      assert :stale_ghosts in checks
    end
  end

  describe "check/1 - git_installed" do
    test "reports ok when git is available" do
      result = Medic.check(:git_installed)
      # git should be available in CI and dev environments
      assert result.name == :git_installed
      assert result.status == :ok
      assert result.message =~ "git"
    end
  end

  describe "check/1 - database_ok" do
    test "reports ok when database is accessible" do
      result = Medic.check(:database_ok)
      assert result.name == :database_ok
      assert result.status == :ok
      assert result.message =~ "accessible"
    end
  end

  describe "check/1 - section_initialized" do
    test "returns a check result with name and status" do
      result = Medic.check(:gitf_initialized)
      assert result.name == :gitf_initialized
      assert result.status in [:ok, :error]
      assert is_binary(result.message)
    end
  end

  describe "check/1 - orphan_shells" do
    test "reports ok when no orphan shells exist" do
      result = Medic.check(:orphan_shells)
      assert result.name == :orphan_shells
      assert result.status == :ok
      assert result.message =~ "No orphan"
    end

    test "reports warn when orphan shells exist" do
      # Create a sector, a stopped ghost, and an active shell for that ghost
      {:ok, sector} =
        Archive.insert(:sectors, %{name: "orphan-test-sector-#{:erlang.unique_integer([:positive])}"})

      {:ok, ghost} =
        Archive.insert(:ghosts, %{name: "orphan-ghost", status: "stopped"})

      {:ok, _cell} =
        Archive.insert(:shells, %{
          ghost_id: ghost.id,
          sector_id: sector.id,
          worktree_path: "/tmp/fake-worktree",
          branch: "ghost/#{ghost.id}",
          status: "active"
        })

      result = Medic.check(:orphan_shells)
      assert result.name == :orphan_shells
      assert result.status == :warn
      assert result.fixable == true
      assert result.message =~ "orphan shell"
    end
  end

  describe "check/1 - stale_ghosts" do
    test "reports ok when no stale ghosts exist" do
      result = Medic.check(:stale_ghosts)
      assert result.name == :stale_ghosts
      assert result.status == :ok
    end

    test "reports warn when stale ghosts exist" do
      {:ok, _bee} =
        Archive.insert(:ghosts, %{name: "stale-ghost", status: "starting", pid: nil})

      result = Medic.check(:stale_ghosts)
      assert result.name == :stale_ghosts
      assert result.status == :warn
      assert result.fixable == true
      assert result.message =~ "stale ghost"
    end
  end

  describe "fix/1 - orphan_shells" do
    test "cleans up orphan shells" do
      {:ok, sector} =
        Archive.insert(:sectors, %{name: "fix-orphan-sector-#{:erlang.unique_integer([:positive])}"})

      {:ok, ghost} =
        Archive.insert(:ghosts, %{name: "fix-orphan-ghost", status: "crashed"})

      {:ok, _cell} =
        Archive.insert(:shells, %{
          ghost_id: ghost.id,
          sector_id: sector.id,
          worktree_path: "/tmp/fake-fix-worktree",
          branch: "ghost/#{ghost.id}",
          status: "active"
        })

      result = Medic.fix(:orphan_shells)
      assert result.name == :orphan_shells
      assert result.status == :ok
      assert result.message =~ "Fixed"
    end
  end

  describe "fix/1 - stale_ghosts" do
    test "marks stale ghosts as crashed" do
      {:ok, ghost} =
        Archive.insert(:ghosts, %{name: "fix-stale-ghost", status: "working", pid: nil})

      result = Medic.fix(:stale_ghosts)
      assert result.name == :stale_ghosts
      assert result.status == :ok
      assert result.message =~ "Marked"

      # Verify the ghost was updated
      updated = Archive.get(:ghosts, ghost.id)
      assert updated.status == "crashed"
    end
  end

  describe "fix/1 - queen_workspace" do
    test "regenerates QUEEN.md when in a gitf workspace" do
      case GiTF.gitf_dir() do
        {:ok, path} ->
          queen_md = Path.join([path, ".gitf", "major", "QUEEN.md"])
          # Remove it so fix can regenerate
          File.rm(queen_md)

          result = Medic.fix(:major_workspace)
          assert result.name == :major_workspace
          assert result.status == :ok
          assert result.message =~ "Regenerated"
          assert File.exists?(queen_md)

        {:error, _} ->
          # Not in a gitf workspace, skip
          :ok
      end
    end
  end

  describe "fix/1 - config_valid" do
    test "regenerates config.toml when in a gitf workspace" do
      case GiTF.gitf_dir() do
        {:ok, path} ->
          config_path = Path.join([path, ".gitf", "config.toml"])
          # Corrupt the config
          File.write(config_path, "invalid toml content [[[")

          result = Medic.fix(:config_valid)
          assert result.name == :config_valid
          assert result.status == :ok
          assert result.message =~ "Regenerated"

          # Verify config is valid again
          assert {:ok, _} = GiTF.Config.read_config(config_path)

        {:error, _} ->
          # Not in a gitf workspace, skip
          :ok
      end
    end
  end

  describe "check/1 - settings_valid" do
    test "reports ok when no settings files exist" do
      result = Medic.check(:settings_valid)
      assert result.name == :settings_valid
      # Either :ok (no files to check) or :warn (not in workspace)
      assert result.status in [:ok, :warn]
    end

    test "reports warn when a settings file has old-format hooks" do
      case GiTF.gitf_dir() do
        {:ok, path} ->
          queen_claude_dir = Path.join([path, ".gitf", "major", ".claude"])
          settings_path = Path.join(queen_claude_dir, "settings.json")
          File.mkdir_p!(queen_claude_dir)

          old_format = %{
            "permissions" => %{"allow" => []},
            "hooks" => %{
              "SessionStart" => [
                %{"type" => "command", "command" => "gitf brief --queen"}
              ]
            }
          }

          File.write!(settings_path, Jason.encode!(old_format))

          result = Medic.check(:settings_valid)
          assert result.name == :settings_valid
          assert result.status == :warn
          assert result.fixable == true
          assert result.message =~ "outdated"

        {:error, _} ->
          :ok
      end
    end
  end

  describe "fix/1 - settings_valid" do
    test "reports no regeneration needed in API mode" do
      case GiTF.gitf_dir() do
        {:ok, _path} ->
          # In API mode, settings files are skipped (no CLI process to configure)
          result = Medic.fix(:settings_valid)
          assert result.name == :settings_valid
          assert result.status == :ok

        {:error, _} ->
          :ok
      end
    end
  end

  describe "fix/1 - unfixable check" do
    test "returns error for non-fixable checks" do
      result = Medic.fix(:git_installed)
      assert result.status == :error
      assert result.message =~ "Not fixable"
    end
  end

  describe "run_all/0" do
    test "returns results for all checks" do
      results = Medic.run_all()
      assert is_list(results)
      assert length(results) == length(Medic.checks())

      Enum.each(results, fn r ->
        assert is_atom(r.name)
        assert r.status in [:ok, :warn, :error]
        assert is_binary(r.message)
        assert is_boolean(r.fixable)
      end)
    end
  end

  describe "run_all/1 with fix: true" do
    test "auto-fixes fixable issues" do
      {:ok, _bee} =
        Archive.insert(:ghosts, %{name: "autofix-ghost", status: "starting", pid: nil})

      results = Medic.run_all(fix: true)

      stale_result = Enum.find(results, &(&1.name == :stale_ghosts))
      assert stale_result.status == :ok
    end
  end
end
