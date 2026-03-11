defmodule GiTF.Runtime.LoadoutTest do
  use ExUnit.Case, async: true

  alias GiTF.Runtime.Loadout

  setup do
    dir = Path.join(System.tmp_dir!(), "toolbox_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "tools/1" do
    test "returns a list of tools for :standard set", %{dir: dir} do
      tools = Loadout.tools(working_dir: dir, tool_set: :standard)
      assert is_list(tools)
      assert length(tools) > 0

      names = Enum.map(tools, & &1.name)
      assert "read_file" in names
      assert "write_file" in names
      assert "run_bash" in names
      assert "search_files" in names
      assert "list_directory" in names
      assert "git_diff" in names
      assert "git_status" in names
      assert "git_add" in names
      assert "git_commit" in names
    end

    test "returns readonly tools for :readonly set", %{dir: dir} do
      tools = Loadout.tools(working_dir: dir, tool_set: :readonly)
      names = Enum.map(tools, & &1.name)

      assert "read_file" in names
      assert "search_files" in names
      assert "list_directory" in names
      refute "write_file" in names
      refute "run_bash" in names
    end

    test "returns queen tools for :major set", %{dir: dir} do
      tools = Loadout.tools(working_dir: dir, tool_set: :major)
      names = Enum.map(tools, & &1.name)

      # Has standard tools
      assert "read_file" in names
      assert "write_file" in names

      # Plus queen-specific tools
      assert "list_quests" in names
      assert "list_bees" in names
      assert "check_costs" in names
    end

    test "defaults to :standard tool set", %{dir: dir} do
      standard = Loadout.tools(working_dir: dir, tool_set: :standard)
      default = Loadout.tools(working_dir: dir)
      assert length(standard) == length(default)
    end
  end

  describe "resolve_path/2" do
    test "resolves relative path against working dir", %{dir: dir} do
      result = Loadout.resolve_path("foo/bar.ex", dir)
      assert result == Path.join(dir, "foo/bar.ex")
    end

    test "raises on path traversal", %{dir: dir} do
      assert_raise RuntimeError, ~r/traversal detected/, fn ->
        Loadout.resolve_path("../../etc/passwd", dir)
      end
    end
  end

  describe "tool execution" do
    test "read_file tool reads a file", %{dir: dir} do
      path = Path.join(dir, "hello.txt")
      File.write!(path, "hello world")

      tools = Loadout.tools(working_dir: dir, tool_set: :readonly)
      read_tool = Enum.find(tools, &(&1.name == "read_file"))

      assert {:ok, "hello world"} = ReqLLM.Tool.execute(read_tool, %{"path" => "hello.txt"})
    end

    test "write_file tool creates a file", %{dir: dir} do
      tools = Loadout.tools(working_dir: dir, tool_set: :standard)
      write_tool = Enum.find(tools, &(&1.name == "write_file"))

      assert {:ok, _} = ReqLLM.Tool.execute(write_tool, %{"path" => "new.txt", "content" => "created"})
      assert File.read!(Path.join(dir, "new.txt")) == "created"
    end

    test "list_directory tool lists files", %{dir: dir} do
      File.write!(Path.join(dir, "a.txt"), "")
      File.write!(Path.join(dir, "b.txt"), "")

      tools = Loadout.tools(working_dir: dir, tool_set: :readonly)
      list_tool = Enum.find(tools, &(&1.name == "list_directory"))

      assert {:ok, listing} = ReqLLM.Tool.execute(list_tool, %{})
      assert listing =~ "a.txt"
      assert listing =~ "b.txt"
    end

    test "run_bash tool executes a command", %{dir: dir} do
      tools = Loadout.tools(working_dir: dir, tool_set: :standard)
      bash_tool = Enum.find(tools, &(&1.name == "run_bash"))

      assert {:ok, result} = ReqLLM.Tool.execute(bash_tool, %{"command" => "echo hello"})
      assert result =~ "hello"
      assert result =~ "Exit code: 0"
    end
  end
end
