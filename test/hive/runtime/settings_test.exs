defmodule Hive.Runtime.SettingsTest do
  use ExUnit.Case, async: true

  alias Hive.Runtime.Settings

  @tmp_dir System.tmp_dir!()

  defp tmp_workspace do
    name = "hive_settings_test_#{:erlang.unique_integer([:positive])}"
    path = Path.join(@tmp_dir, name)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  describe "build_settings/2" do
    test "produces a map with SessionStart and Stop hooks" do
      settings = Settings.build_settings("bee-abc123", "/home/user/hive")

      assert %{"hooks" => hooks} = settings
      assert Map.has_key?(hooks, "SessionStart")
      assert Map.has_key?(hooks, "Stop")
    end

    test "SessionStart hook runs hive prime with the bee ID" do
      settings = Settings.build_settings("bee-abc123", "/tmp/test-hive")

      [%{"matcher" => "", "hooks" => [hook]}] = settings["hooks"]["SessionStart"]
      assert hook["type"] == "command"
      assert hook["command"] =~ "prime --bee bee-abc123"
    end

    test "Stop hook runs hive costs record with the bee ID" do
      settings = Settings.build_settings("bee-abc123", "/tmp/test-hive")

      [%{"matcher" => "", "hooks" => [hook]}] = settings["hooks"]["Stop"]
      assert hook["type"] == "command"
      assert hook["command"] =~ "costs record --bee bee-abc123"
    end

    test "includes permissions with allowed tools" do
      settings = Settings.build_settings("bee-abc123", "/tmp/test-hive")

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

    test "allowed tools include the hive binary" do
      settings = Settings.build_settings("bee-abc123", "/tmp/test-hive")

      tools = settings["permissions"]["allow"]
      assert Enum.any?(tools, &String.contains?(&1, "hive"))
    end
  end

  describe "build_queen_settings/1" do
    test "includes permissions with allowed tools" do
      settings = Settings.build_queen_settings("/tmp/test-hive")

      assert %{"permissions" => %{"allow" => tools}} = settings
      assert is_list(tools)
      assert "Read" in tools
      assert "Glob" in tools
      assert "Grep" in tools
      # Queen must NOT have write/edit/destructive tools
      refute "Write" in tools
      refute "Edit" in tools
    end

    test "SessionStart hook runs hive prime --queen" do
      settings = Settings.build_queen_settings("/tmp/test-hive")

      [%{"matcher" => "", "hooks" => [hook]}] = settings["hooks"]["SessionStart"]
      assert hook["type"] == "command"
      assert hook["command"] =~ "prime --queen"
    end

    test "Stop hook runs hive costs record --queen" do
      settings = Settings.build_queen_settings("/tmp/test-hive")

      [%{"matcher" => "", "hooks" => [hook]}] = settings["hooks"]["Stop"]
      assert hook["type"] == "command"
      assert hook["command"] =~ "costs record --queen"
    end
  end

  describe "generate_queen/2" do
    test "writes queen settings to the workspace" do
      workspace = tmp_workspace()

      assert :ok = Settings.generate_queen("/tmp/hive-root", workspace)

      settings_path = Path.join([workspace, ".claude", "settings.json"])
      assert File.exists?(settings_path)

      {:ok, content} = File.read(settings_path)
      {:ok, parsed} = Jason.decode(content)

      assert parsed["permissions"]["allow"] != nil
      assert parsed["hooks"]["SessionStart"] != nil
    end
  end

  describe "generate/3" do
    test "writes .claude/settings.json to the working directory" do
      working_dir = tmp_workspace()

      assert :ok = Settings.generate("bee-test1", "/tmp/hive-root", working_dir)

      settings_path = Path.join([working_dir, ".claude", "settings.json"])
      assert File.exists?(settings_path)

      {:ok, content} = File.read(settings_path)
      {:ok, parsed} = Jason.decode(content)

      assert parsed["hooks"]["SessionStart"] != nil
      assert parsed["hooks"]["Stop"] != nil
    end

    test "creates the .claude directory if it does not exist" do
      working_dir = tmp_workspace()
      claude_dir = Path.join(working_dir, ".claude")

      refute File.dir?(claude_dir)

      :ok = Settings.generate("bee-test2", "/tmp/hive-root", working_dir)

      assert File.dir?(claude_dir)
    end
  end
end
