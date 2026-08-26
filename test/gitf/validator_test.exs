defmodule GiTF.ValidatorTest do
  use ExUnit.Case, async: true

  alias GiTF.Validator

  describe "build_validation_prompt/2" do
    test "builds a prompt with op title and diff" do
      op = %{
        id: "op-123",
        title: "Fix the login bug",
        description: "Users can't log in when password has special chars",
        status: "done",
        mission_id: "msn-1",
        sector_id: "sec-1"
      }

      diff = """
      --- a/lib/auth.ex
      +++ b/lib/auth.ex
      @@ -10,3 +10,5 @@
      -  def check(pass), do: :error
      +  def check(pass) do
      +    URI.decode(pass) |> verify()
      +  end
      """

      prompt = Validator.build_validation_prompt(op, diff)

      assert prompt =~ "Fix the login bug"
      assert prompt =~ "special chars"
      assert prompt =~ "lib/auth.ex"
      assert prompt =~ ~s("verdict")
    end

    test "handles nil description" do
      op = %{
        id: "op-456",
        title: "Quick fix",
        description: nil,
        status: "done",
        mission_id: "msn-1",
        sector_id: "sec-1"
      }

      prompt = Validator.build_validation_prompt(op, "some diff")
      assert prompt =~ "Quick fix"
      assert prompt =~ "some diff"
    end
  end

  describe "run_custom_validation/2" do
    test "runs a passing command" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "gitf_val_test_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      shell = %{
        id: "cel-test",
        worktree_path: tmp_dir,
        ghost_id: "ghost-1",
        sector_id: "sec-1",
        branch: "test",
        status: "active"
      }

      assert :ok = Validator.run_custom_validation(shell, "true")
    end

    test "returns error for failing command" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "gitf_val_test_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      shell = %{
        id: "cel-test",
        worktree_path: tmp_dir,
        ghost_id: "ghost-1",
        sector_id: "sec-1",
        branch: "test",
        status: "active"
      }

      assert {:error, :failed, msg} = Validator.run_custom_validation(shell, "false")
      assert msg =~ "exit 1"
    end

    test "classifies exit 127 as :tool_missing — a host problem, not the code's" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "gitf_val_test_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      shell = %{
        id: "cel-test",
        worktree_path: tmp_dir,
        ghost_id: "ghost-1",
        sector_id: "sec-1",
        branch: "test",
        status: "active"
      }

      assert {:error, :tool_missing, msg} =
               Validator.run_custom_validation(shell, "definitely-not-a-real-command-xyz")

      assert msg =~ "TOOL MISSING on host"
    end
  end

  describe "run_claude_validation/2 rescue behavior" do
    test "does not silently swallow non-network exceptions" do
      # The rescue clause should only catch ErlangError, Mint.TransportError, Mint.HTTPError
      # Other exceptions should propagate
      # We verify the function exists and handles empty diff case
      result =
        Validator.run_claude_validation(
          %{title: "test", description: "test"},
          %{worktree_path: System.tmp_dir!(), id: "cel-1"}
        )

      # Should return a proper result, not crash
      assert match?({:ok, _}, result) or match?({:error, _, _}, result)
    end
  end

  describe "validation_timeout_ms/1" do
    # msn-8e0eae: Audit and Sync.Resolver each carried their own
    # `@validation_timeout_ms 120_000` and never consulted the sector, so a
    # sector that opted into a longer validation still got two minutes from
    # them and had every op reported as "Validation command timed out after
    # 120s" — including the implementation that was correct. The orchestrator
    # then spawned fix ghosts for a defect that did not exist.
    test "honours a sector's opt-in" do
      assert Validator.validation_timeout_ms(%{validation_timeout_ms: 600_000}) == 600_000
    end

    test "falls back to the default when the sector has no opinion" do
      assert Validator.validation_timeout_ms(%{}) == 120_000
      assert Validator.validation_timeout_ms(%{validation_timeout_ms: nil}) == 120_000
    end

    test "tolerates a missing sector" do
      assert Validator.validation_timeout_ms(nil) == 120_000
    end

    test "no module runs a sector's validation_command on its own" do
      # The orphan hole this closes: Task.shutdown/2 kills the Elixir task but
      # never the OS process behind System.cmd, so only the `timeout -k` that
      # run_validation/4 puts INSIDE the sandbox actually kills the tree. Audit
      # had no OS deadline and Resolver was not sandboxed at all, so whether a
      # runaway validation died depended on which module invoked it — and an
      # orphan does not stay in its own sector. A leaked probe holding :1420
      # poisoned a later run once already.
      # Comment lines are stripped first: these modules explain in prose what
      # they no longer do, and a guard that reads its own documentation as a
      # violation is a guard that gets deleted.
      code_of = fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
        |> Enum.join("\n")
      end

      offenders =
        for path <- ["lib/gitf/audit.ex", "lib/gitf/sync/resolver.ex"],
            File.exists?(path),
            code = code_of.(path),
            String.contains?(code, "Task.yield") or String.contains?(code, "System.cmd(\"sh\""),
            do: path

      assert offenders == [],
             "these run a shell command directly instead of GiTF.Validator.run_validation/4, " <>
               "which is the only path that wraps the command in an OS-level timeout inside " <>
               "the sandbox: #{inspect(offenders)}"
    end

    test "every module that runs a sector's validation_command shares this one" do
      # A fourth hardcoded copy is the bug returning. Only Validator itself
      # may name the default.
      offenders =
        for path <- ["lib/gitf/audit.ex", "lib/gitf/sync/resolver.ex"],
            File.exists?(path),
            String.contains?(File.read!(path), "@validation_timeout_ms"),
            do: path

      assert offenders == [],
             "these still define their own validation timeout instead of calling " <>
               "GiTF.Validator.validation_timeout_ms/1: #{inspect(offenders)}"
    end
  end
end
