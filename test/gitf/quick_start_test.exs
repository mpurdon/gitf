defmodule GiTF.QuickStartTest do
  use GiTF.StoreCase

  alias GiTF.QuickStart

  @tmp_dir System.tmp_dir!()

  describe "detect_environment/1" do
    test "detects environment for a plain directory" do
      path = create_temp_dir("qs_detect_plain")

      env = QuickStart.detect_environment(path)

      assert env.path == path
      assert is_boolean(env.has_git)
      assert is_boolean(env.has_claude)
      assert env.is_git_repo == false
      assert env.is_section == false
      assert env.git_repos == []
    end

    test "detects git repos in subdirectories" do
      parent = create_temp_dir("qs_detect_repos")
      _repo_a = create_git_repo_in(parent, "repo-alpha")
      _non_repo = create_plain_dir_in(parent, "not-a-repo")

      env = QuickStart.detect_environment(parent)

      assert length(env.git_repos) == 1
      # Check by basename since macOS symlinks /tmp -> /private/tmp
      basenames = Enum.map(env.git_repos, &Path.basename/1)
      assert "repo-alpha" in basenames
    end

    test "detects when already a section" do
      path = create_temp_dir("qs_detect_section")
      File.mkdir_p!(Path.join(path, ".gitf"))

      env = QuickStart.detect_environment(path)

      assert env.is_section == true
    end

    test "detects when current dir is a git repo" do
      path = create_temp_dir("qs_detect_gitrepo")
      init_git_repo(path)

      env = QuickStart.detect_environment(path)

      assert env.is_git_repo == true
    end
  end

  describe "quick_init/1" do
    test "initializes a section and returns a summary" do
      path = create_temp_dir("qs_init_basic")

      assert {:ok, summary} = QuickStart.quick_init(path)

      assert summary.section_path == path
      assert File.dir?(Path.join(path, ".gitf"))
      assert summary.sectors_registered == []
    end

    test "auto-discovers and registers git repos" do
      parent = create_temp_dir("qs_init_discover")
      create_git_repo_in(parent, "project-one")
      create_git_repo_in(parent, "project-two")

      assert {:ok, summary} = QuickStart.quick_init(parent)

      assert length(summary.sectors_registered) == 2

      names = Enum.map(summary.sectors_registered, fn {:ok, name} -> name end)
      assert "project-one" in names
      assert "project-two" in names

      # Verify they are actually in the database
      sectors = GiTF.Sector.list()
      sector_names = Enum.map(sectors, & &1.name)
      assert "project-one" in sector_names
      assert "project-two" in sector_names
    end

    test "returns error when already initialized and not forced" do
      path = create_temp_dir("qs_init_dup")
      gitf_dir = Path.join(path, ".gitf")
      File.mkdir_p!(gitf_dir)
      File.write!(Path.join(gitf_dir, "config.toml"), "")

      assert {:error, :already_initialized} = QuickStart.quick_init(path)
    end

    test "reinitializes with force option" do
      path = create_temp_dir("qs_init_force")
      gitf_dir = Path.join(path, ".gitf")
      File.mkdir_p!(gitf_dir)
      File.write!(Path.join(gitf_dir, "config.toml"), "")

      assert {:ok, _summary} = QuickStart.quick_init(path, force: true)
    end
  end

  describe "generate_sector_claude_md/2" do
    test "generates markdown with sector name and link_msg instructions" do
      md = QuickStart.generate_sector_claude_md("my-project", "/path/to/my-project")

      assert md =~ "my-project"
      assert md =~ "link"
      assert md =~ "major"
      assert md =~ "/path/to/my-project"
      assert md =~ "op_complete"
      assert md =~ "op_blocked"
    end
  end

  # -- Helpers ---------------------------------------------------------------

  defp create_temp_dir(name) do
    path = Path.join(@tmp_dir, "gitf_qs_test_#{name}_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp create_git_repo_in(parent, name) do
    path = Path.join(parent, name)
    File.mkdir_p!(path)
    init_git_repo(path)

    # Resolve symlinks (macOS /tmp -> /private/tmp)
    {real_path, 0} =
      System.cmd("git", ["rev-parse", "--show-toplevel"],
        cd: path,
        stderr_to_stdout: true
      )

    String.trim(real_path)
  end

  defp create_plain_dir_in(parent, name) do
    path = Path.join(parent, name)
    File.mkdir_p!(path)
    path
  end

  defp init_git_repo(path) do
    System.cmd("git", ["init"], cd: path, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@gitf.local"], cd: path)
    System.cmd("git", ["config", "user.name", "Test"], cd: path)

    readme = Path.join(path, "README.md")
    File.write!(readme, "# Test\n")
    System.cmd("git", ["add", "."], cd: path, stderr_to_stdout: true)
    System.cmd("git", ["commit", "-m", "initial"], cd: path, stderr_to_stdout: true)
  end
end
