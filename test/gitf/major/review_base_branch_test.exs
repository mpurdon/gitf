defmodule GiTF.Major.ReviewBaseBranchTest do
  @moduledoc """
  A mission amending an open pull request must WORK ON that branch, not merely
  merge into it at the end.

  target_branch was applied only in Sync.merge_quest, so every ghost worktree
  was cut from main. On msn-dd29a1 the file under review did not exist on main
  at all: no ghost ever saw the code it was asked to change, the correct commit
  fell out of a union merge rather than an edit, and validation then diffed a
  tree without the change and reported the work missing — a false failure on a
  run that had actually done the right thing.
  """
  use ExUnit.Case, async: true

  @source File.read!("lib/gitf/major/orchestrator.ex")

  test "phase ghosts inherit the branch being amended" do
    # Every phase — triage, design, validation — spawns through here, so one
    # default covers them all rather than each caller remembering.
    assert @source =~
             ~r/spawn_opts =\s*\n\s*\[prompt: prompt\]\s*\n\s*\|> Keyword\.merge\(mission_base_branch_opts\(mission\)\)/
  end

  test "an explicit base_branch from the caller still wins" do
    # Chained impl ops and tournament variants pass a specific base; the
    # mission default must not override it.
    idx_default = :binary.match(@source, "Keyword.merge(mission_base_branch_opts(mission))")
    idx_explicit = :binary.match(@source, "Keyword.merge(Keyword.take(opts, [:base_branch]))")

    assert idx_default != :nomatch and idx_explicit != :nomatch
    {default_at, _} = idx_default
    {explicit_at, _} = idx_explicit
    assert explicit_at > default_at, "the caller's base_branch must be merged last"
  end

  test "implementation falls back to the amended branch, not sector HEAD" do
    assert @source =~ ~r/_ ->\s*\n\s*mission_base_branch_opts\(mission\)/
  end

  test "the helper only applies when a branch is actually set" do
    assert @source =~
             ~r/branch when is_binary\(branch\) and branch != "" -> \[base_branch: branch\]/
  end
end
