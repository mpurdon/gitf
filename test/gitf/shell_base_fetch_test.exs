defmodule GiTF.ShellBaseFetchTest do
  @moduledoc """
  Ghosts must start from the remote's current state.

  The fetch used to live inside remote_base_branch/1, so it ran only when NO
  explicit base was given. That was sound while every explicit base was a
  local ghost branch with nothing to fetch — but once a mission amending a
  pull request started passing that PR's REMOTE branch as its base, the case
  that most needed current code was the one that skipped the refresh. A ghost
  was cut from a branch tip one commit behind what had already been pushed to
  it.
  """
  use ExUnit.Case, async: true

  @source File.read!("lib/gitf/shell.ex")

  test "create/3 fetches before building the worktree" do
    # Unconditional, not hidden behind the no-explicit-base path.
    assert @source =~ ~r/:ok <- fetch_origin\(sector\.path\),\s*\n\s*base_branch = resolve_base_branch/
  end

  test "the fetch is non-fatal so offline sectors still work" do
    assert @source =~ ~r/defp fetch_origin\(repo_path\) do\s*\n\s*_ = Git\.fetch\(repo_path, "origin"\)\s*\n\s*:ok/
  end

  test "an explicit branch base prefers the remote's version" do
    assert @source =~ ~r/"origin\/#\{base\}"/
  end

  test "a local-only base passes through untouched" do
    # ghost/<id> has no remote counterpart; rewriting it would break chained
    # implementation ops, which build on a sibling ghost's local branch.
    assert @source =~ ~r/not Git\.remote_branch_exists\?\(repo_path, "origin\/#\{base\}"\)/
  end

  test "an already-qualified base is not double-prefixed" do
    assert @source =~ ~r/String\.starts_with\?\(base, "origin\/"\)/
  end

  test "remote_base_branch no longer fetches on its own" do
    # It is reached only when no explicit base was given, and create/3 has
    # already fetched by then — fetching twice per ghost is pure latency.
    refute @source =~ ~r/with :ok <- Git\.fetch\(repo_path, "origin"\),/
  end
end
