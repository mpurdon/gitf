defmodule GiTF.Sandbox.SandboxExecTest do
  use ExUnit.Case, async: true

  alias GiTF.Sandbox.SandboxExec

  @moduletag :sandbox

  describe "available?/0" do
    @tag :macos_only
    test "returns true on macOS" do
      if match?({:unix, :darwin}, :os.type()) do
        assert SandboxExec.available?()
      else
        refute SandboxExec.available?()
      end
    end
  end

  describe "name/0" do
    test "returns sandbox-exec" do
      assert SandboxExec.name() == "sandbox-exec"
    end
  end

  describe "wrap_command/3" do
    test "returns correct tuple shape" do
      {cmd, args, opts} = SandboxExec.wrap_command("echo", ["hello"], cd: "/tmp")

      assert cmd == "sandbox-exec"
      assert ["-p", _profile, "echo", "hello"] = args
      assert opts == [cd: "/tmp"]
    end

    test "profile contains deny default and version 1" do
      {_cmd, ["-p", profile | _rest], _opts} =
        SandboxExec.wrap_command("ls", [], cd: "/tmp")

      assert profile =~ "(deny default)"
      assert profile =~ "(version 1)"
    end

    test "critical risk produces read-only cwd access" do
      cwd = "/Users/test/project"

      {_cmd, ["-p", profile | _rest], _opts} =
        SandboxExec.wrap_command("cat", ["file.txt"], cd: cwd, risk_level: :critical)

      assert profile =~ ~s[(allow file-read* (subpath "#{cwd}"))]
      refute profile =~ ~s[(allow file-read* file-write* (subpath "#{cwd}"))]
    end

    test "low risk produces read-write cwd access" do
      cwd = "/Users/test/project"

      {_cmd, ["-p", profile | _rest], _opts} =
        SandboxExec.wrap_command("touch", ["new.txt"], cd: cwd, risk_level: :low)

      assert profile =~ ~s[(allow file-read* file-write* (subpath "#{cwd}"))]
    end

    test "medium risk produces read-write cwd access" do
      {_cmd, ["-p", profile | _rest], _opts} =
        SandboxExec.wrap_command("ls", [], cd: "/tmp/work", risk_level: :medium)

      assert profile =~ ~s[(allow file-read* file-write* (subpath "/tmp/work"))]
    end

    test "high risk produces read-write cwd access" do
      {_cmd, ["-p", profile | _rest], _opts} =
        SandboxExec.wrap_command("ls", [], cd: "/tmp/work", risk_level: :high)

      assert profile =~ ~s[(allow file-read* file-write* (subpath "/tmp/work"))]
    end

    test "cwd path appears in profile" do
      cwd = "/Users/someone/my-project"

      {_cmd, ["-p", profile | _rest], _opts} =
        SandboxExec.wrap_command("ls", [], cd: cwd)

      assert profile =~ cwd
    end

    test "path with spaces is properly escaped" do
      cwd = "/Users/test/my project/code"

      {_cmd, ["-p", profile | _rest], _opts} =
        SandboxExec.wrap_command("ls", [], cd: cwd)

      assert profile =~ ~s[(subpath "/Users/test/my project/code")]
    end

    test "path with quotes is escaped" do
      cwd = ~s[/Users/test/proj"ect]

      {_cmd, ["-p", profile | _rest], _opts} =
        SandboxExec.wrap_command("ls", [], cd: cwd)

      assert profile =~ ~s[(subpath "/Users/test/proj\\"ect")]
    end

    test "defaults to cwd when no :cd opt" do
      {_cmd, ["-p", profile | _rest], _opts} =
        SandboxExec.wrap_command("ls", [], [])

      assert profile =~ File.cwd!()
    end

    test "profile permits AI-CLI home config dirs (so the CLI can run)" do
      {_cmd, ["-p", profile | _rest], _opts} =
        SandboxExec.wrap_command("claude", [], cd: "/tmp/work")

      home = System.user_home()
      assert profile =~ ~s[(allow file-read* file-write* (subpath "#{home}/.claude"))]
      # Broad read of home so node/git/config resolve.
      assert profile =~ ~s[(allow file-read* (subpath "#{home}"))]
    end
  end
end
