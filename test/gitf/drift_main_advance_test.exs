defmodule GiTF.DriftMainAdvanceTest do
  @moduledoc """
  The validation prompt only gets a "main moved" section when main really
  moved, and the section has to describe what landed. Runs against real git
  because the whole point is the merge-base arithmetic.
  """
  use ExUnit.Case, async: true

  alias GiTF.Drift

  @git "/usr/bin/git"

  defp git(path, args), do: System.cmd(@git, args, cd: path, stderr_to_stdout: true)

  defp repo do
    path = Path.join(System.tmp_dir!(), "gitf_drift_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(path)
    git(path, ["init", "--initial-branch=main"])
    git(path, ["config", "user.email", "test@gitf.local"])
    git(path, ["config", "user.name", "Test"])
    File.write!(Path.join(path, "README.md"), "# Test\n")
    git(path, ["add", "."])
    git(path, ["commit", "-m", "initial"])
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp commit(path, file, contents, message) do
    File.write!(Path.join(path, file), contents)
    git(path, ["add", "."])
    git(path, ["commit", "-m", message])
  end

  test "returns nil when the branch has not fallen behind" do
    path = repo()
    git(path, ["checkout", "-b", "feature"])

    assert Drift.main_advance_summary(path, "main") == nil
  end

  test "describes the commits and files that landed after the branch cut" do
    path = repo()
    git(path, ["checkout", "-b", "feature"])
    commit(path, "feature.ts", "export const a = 1\n", "feature work")

    git(path, ["checkout", "main"])
    commit(path, "drawer.tsx", "export const Drawer = () => null\n", "add the drawer")
    commit(path, "lib.ts", "export const resolve = () => 1\n", "add resolve helper")

    git(path, ["checkout", "feature"])
    summary = Drift.main_advance_summary(path, "main")

    assert summary.commits == 2
    assert Enum.any?(summary.subjects, &(&1 =~ "add the drawer"))
    assert Enum.any?(summary.subjects, &(&1 =~ "add resolve helper"))
    assert "drawer.tsx" in summary.files
    assert "lib.ts" in summary.files
    # The branch's own work is not "what landed on main".
    refute "feature.ts" in summary.files
  end

  test "counts only what is missing, not the branch's own divergence" do
    path = repo()
    git(path, ["checkout", "-b", "feature"])
    commit(path, "a.ts", "1\n", "branch commit one")
    commit(path, "b.ts", "2\n", "branch commit two")

    git(path, ["checkout", "main"])
    commit(path, "c.ts", "3\n", "the only main commit")
    git(path, ["checkout", "feature"])

    assert Drift.main_advance_summary(path, "main").commits == 1
  end

  test "an unresolvable ref yields nil rather than raising" do
    path = repo()
    assert Drift.main_advance_summary(path, "origin/nope") == nil
  end
end
