defmodule GiTFTest do
  use ExUnit.Case, async: false

  describe "version/0" do
    test "returns the project version as a string" do
      version = GiTF.version()

      assert is_binary(version)
      assert version =~ ~r/^\d+\.\d+\.\d+/
    end
  end

  describe "gitf_dir/0" do
    test "returns {:error, :not_in_gitf} when no .gitf directory exists" do
      # `gitf_dir/0` resolves via GITF_PATH → walk up from cwd → homedir
      # (`$GITF_HOME || $HOME`) fallback. Block all three so the test
      # genuinely exercises the "no marker anywhere" branch — otherwise
      # the dev machine's own `~/.gitf/config.toml` makes this assert
      # the wrong thing.
      original_path = System.get_env("GITF_PATH")
      original_home = System.get_env("GITF_HOME")
      System.delete_env("GITF_PATH")

      tmp = Path.join(System.tmp_dir!(), "gitf_no_marker_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      System.put_env("GITF_HOME", tmp)

      original_cwd = File.cwd!()
      File.cd!(tmp)

      on_exit(fn ->
        File.cd!(original_cwd)
        File.rm_rf!(tmp)
        if original_path, do: System.put_env("GITF_PATH", original_path)

        if original_home,
          do: System.put_env("GITF_HOME", original_home),
          else: System.delete_env("GITF_HOME")
      end)

      assert {:error, :not_in_gitf} = GiTF.gitf_dir()
    end

    test "finds a .gitf directory via GITF_PATH env var" do
      tmp = System.tmp_dir!()
      gitf_root = Path.join(tmp, "gitf_test_#{:erlang.unique_integer([:positive])}")
      gitf_marker = Path.join(gitf_root, ".gitf")
      File.mkdir_p!(gitf_marker)
      File.write!(Path.join(gitf_marker, "config.toml"), "")

      on_exit(fn -> File.rm_rf!(gitf_root) end)

      System.put_env("GITF_PATH", gitf_root)

      on_exit(fn -> System.delete_env("GITF_PATH") end)

      assert {:ok, ^gitf_root} = GiTF.gitf_dir()
    end
  end
end
