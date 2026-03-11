defmodule GiTF.Runtime.SettingsTest do
  use ExUnit.Case, async: true

  alias GiTF.Runtime.Settings

  @tmp_dir System.tmp_dir!()

  defp tmp_workspace do
    name = "gitf_settings_test_#{:erlang.unique_integer([:positive])}"
    path = Path.join(@tmp_dir, name)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  describe "build_settings/2" do
    test "produces a map with SessionStart and Stop hooks" do
      settings = Settings.build_settings("ghost-abc123", "/home/user/hive")

      assert %{"hooks" => hooks} = settings
      assert Map.has_key?(hooks, "SessionStart")
      assert Map.has_key?(hooks, "Stop")
    end

    test "SessionStart hook runs section brief with the ghost ID" do
      settings = Settings.build_settings("ghost-abc123", "/tmp/test-gitf")

      [%{"matcher" => "", "hooks" => [hook]}] = settings["hooks"]["SessionStart"]
      assert hook["type"] == "command"
      assert hook["command"] =~ "brief --ghost ghost-abc123"
    end

    test "Stop hook runs section costs record with the ghost ID" do
      settings = Settings.build_settings("ghost-abc123", "/tmp/test-gitf")

      [%{"matcher" => "", "hooks" => [hook]}] = settings["hooks"]["Stop"]
      assert hook["type"] == "command"
      assert hook["command"] =~ "costs record --ghost ghost-abc123"
    end

    test "includes permissions with allowed tools" do
      settings = Settings.build_settings("ghost-abc123", "/tmp/test-gitf")

      assert %{"permissions" => %{"allow" => tools}} = settings
      assert is_list(tools)
      assert "Read" in tools
      assert "Write" in tools
      assert "Edit" in tools
      assert "Glob" in tools
      assert "Grep" in tools
      assert "Bash(git:*)" in tools
      assert "Bash(mix:*)" in tools
    end

    test "allowed tools include the section binary" do
      settings = Settings.build_settings("ghost-abc123", "/tmp/test-gitf")

      tools = settings["permissions"]["allow"]
      assert Enum.any?(tools, &String.contains?(&1, "gitf"))
    end
  end

  describe "build_major_settings/1" do
    test "includes permissions with allowed tools" do
      settings = Settings.build_major_settings("/tmp/test-gitf")

      assert %{"permissions" => %{"allow" => tools}} = settings
      assert is_list(tools)
      assert "Read" in tools
      assert "Glob" in tools
      assert "Grep" in tools
      # Major must NOT have write/edit/destructive tools
      refute "Write" in tools
      refute "Edit" in tools
    end

    test "SessionStart hook runs section brief --queen" do
      settings = Settings.build_major_settings("/tmp/test-gitf")

      [%{"matcher" => "", "hooks" => [hook]}] = settings["hooks"]["SessionStart"]
      assert hook["type"] == "command"
      assert hook["command"] =~ "brief --queen"
    end

    test "Stop hook runs section costs record --queen" do
      settings = Settings.build_major_settings("/tmp/test-gitf")

      [%{"matcher" => "", "hooks" => [hook]}] = settings["hooks"]["Stop"]
      assert hook["type"] == "command"
      assert hook["command"] =~ "costs record --queen"
    end
  end

  describe "generate_major/2" do
    test "skips writing settings in API mode" do
      workspace = tmp_workspace()

      # In API mode, no CLI settings file is needed
      assert :ok = Settings.generate_major("/tmp/hive-root", workspace)

      settings_path = Path.join([workspace, ".claude", "settings.json"])
      refute File.exists?(settings_path)
    end
  end

  describe "generate/3" do
    test "skips writing settings in API mode" do
      working_dir = tmp_workspace()

      # In API mode, no CLI settings file is needed
      assert :ok = Settings.generate("ghost-test1", "/tmp/hive-root", working_dir)

      settings_path = Path.join([working_dir, ".claude", "settings.json"])
      refute File.exists?(settings_path)
    end

    test "does not create .claude directory in API mode" do
      working_dir = tmp_workspace()
      claude_dir = Path.join(working_dir, ".claude")

      refute File.dir?(claude_dir)

      :ok = Settings.generate("ghost-test2", "/tmp/hive-root", working_dir)

      refute File.dir?(claude_dir)
    end
  end
end
