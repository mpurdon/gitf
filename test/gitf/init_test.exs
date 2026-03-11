defmodule GiTF.InitTest do
  use ExUnit.Case, async: false

  @tmp_dir System.tmp_dir!()

  setup do
    tmp_dir = Path.join(@tmp_dir, "gitf_store_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Archive.start_link(data_dir: tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    :ok
  end

  defp tmp_workspace do
    path = Path.join(@tmp_dir, "gitf_init_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  describe "init/2" do
    test "creates the .gitf directory structure" do
      workspace = tmp_workspace()

      assert {:ok, ^workspace} = GiTF.Init.init(workspace)

      assert File.dir?(Path.join(workspace, ".gitf"))
      assert File.dir?(Path.join([workspace, ".gitf", "major"]))
      assert File.exists?(Path.join([workspace, ".gitf", "config.toml"]))
      assert File.exists?(Path.join([workspace, ".gitf", "major", "QUEEN.md"]))
    end

    test "writes a valid TOML config" do
      workspace = tmp_workspace()

      {:ok, _} = GiTF.Init.init(workspace)

      config_path = Path.join([workspace, ".gitf", "config.toml"])
      assert {:ok, config} = GiTF.Config.read_config(config_path)
      assert config["major"]["max_ghosts"] == 5
    end

    test "writes QUEEN.md with delegation instructions" do
      workspace = tmp_workspace()

      {:ok, _} = GiTF.Init.init(workspace)

      queen_path = Path.join([workspace, ".gitf", "major", "QUEEN.md"])
      content = File.read!(queen_path)

      assert content =~ "Major Instructions"
      assert content =~ "COORDINATION, not coding"
      assert content =~ "NEVER write the code yourself"
    end

    test "refuses to reinitialize without --force" do
      workspace = tmp_workspace()

      {:ok, _} = GiTF.Init.init(workspace)
      assert {:error, :already_initialized} = GiTF.Init.init(workspace)
    end

    test "reinitializes with force: true" do
      workspace = tmp_workspace()

      {:ok, _} = GiTF.Init.init(workspace)
      assert {:ok, ^workspace} = GiTF.Init.init(workspace, force: true)
    end

    test "expands paths to absolute form" do
      workspace = tmp_workspace()

      {:ok, result} = GiTF.Init.init(workspace)

      assert Path.type(result) == :absolute
    end
  end
end
