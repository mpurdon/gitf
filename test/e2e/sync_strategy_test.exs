defmodule GiTF.E2E.SyncStrategyTest do
  @moduledoc """
  E2E tests for sector sync strategies (auto_merge, pr_branch, manual).

  Exercises the full pipeline:
    ghost makes changes → auto-commit → SyncQueue → Resolver strategy dispatch → verify end state

  Tachikoma is not started in test env, so we bridge directly to SyncQueue
  after ghost completion (simulating a passed verification).
  """

  use GiTF.TestDriver.Scenario

  # -- Helpers ---------------------------------------------------------------

  # The codebase uses "git sync" for "git merge" and "git sync-base" for
  # "git merge-base". Set up git aliases in the test repo so these work.
  defp setup_git_aliases(repo_path) do
    System.cmd("git", ["config", "alias.sync", "merge"], cd: repo_path)
    System.cmd("git", ["config", "alias.sync-base", "merge-base"], cd: repo_path)
  end

  # Create sector and set its sync_strategy, with git aliases configured
  defp add_sector_with_strategy(env, strategy) do
    {:ok, env, sector} = Harness.add_sector(env)

    # Set up git aliases for the "sync" commands
    setup_git_aliases(sector.path)

    # Update the sector's sync_strategy in Archive
    updated = Map.put(sector, :sync_strategy, strategy)
    GiTF.Archive.put(:sectors, updated)

    {:ok, env, updated}
  end

  # Write a mock script that creates a specific file in the working directory
  defp write_file_creating_mock(dir, filename, content) do
    name = "mock_fc_#{:erlang.unique_integer([:positive])}.sh"
    path = Path.join(dir, name)
    session_id = "test-session-#{:erlang.unique_integer([:positive])}"

    File.write!(path, """
    #!/bin/bash
    echo '#{content}' > #{filename}
    cat <<'MOCK_OUTPUT'
    {"type":"system","session_id":"#{session_id}","model":"claude-sonnet-4-20250514"}
    {"type":"assistant","content":"Created #{filename}"}
    {"type":"result","model":"claude-sonnet-4-20250514","usage":{"input_tokens":100,"output_tokens":50,"cache_read_tokens":0,"cache_write_tokens":0},"cost_usd":0.001}
    MOCK_OUTPUT
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  # Start SyncQueue if not running (skipped in test env)
  defp ensure_sync_queue do
    case GiTF.Sync.Queue.lookup() do
      {:ok, _pid} ->
        :ok

      :error ->
        {:ok, _pid} = GiTF.Sync.Queue.start_link()
        :ok
    end
  end

  # Simulate Tachikoma passing verification
  defp bridge_to_sync_queue(op_id, shell_id) do
    Phoenix.PubSub.broadcast(GiTF.PubSub, "sync:queue", {:merge_ready, op_id, shell_id})
  end

  defp shell_for_ghost(ghost_id) do
    GiTF.Archive.find_one(:shells, fn c ->
      c.ghost_id == ghost_id and c.status == "active"
    end)
  end

  defp current_branch(repo_path) do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  end

  defp file_on_branch?(repo_path, filename) do
    File.exists?(Path.join(repo_path, filename))
  end

  defp await_sync_idle(timeout \\ 10_000) do
    await(
      fn ->
        status = GiTF.Sync.Queue.status()
        status.active == nil
      end, timeout: timeout, message: "SyncQueue did not become idle")
  end

  defp spawn_ghost_with_file(env, op_id, sector_id, filename, content) do
    script = write_file_creating_mock(env.mock_dir, filename, content)
    GiTF.Ghosts.spawn(op_id, sector_id, env.gitf_root, claude_executable: script, prompt: "test")
  end

  # =========================================================================
  # Scenarios
  # =========================================================================

  scenario "auto_merge: ghost changes are committed and merged to main" do
    {:ok, env, sector} = add_sector_with_strategy(env, "auto_merge")
    ensure_sync_queue()

    {:ok, _mission, [op]} =
      Harness.create_quest(env,
        sector_id: sector.id,
        goal: "Auto-merge test",
        ops: [%{title: "Create a file"}]
      )

    {:ok, ghost} =
      spawn_ghost_with_file(env, op.id, sector.id, "auto_merge_result.txt", "auto merged")

    # Wait for ghost to complete
    await({:job_done, op.id}, timeout: 20_000)
    await({:bee_stopped, ghost.id}, timeout: 10_000)

    # Verify auto-commit happened in the worktree
    shell = shell_for_ghost(ghost.id)
    assert shell != nil, "Shell should exist for ghost"

    {log_output, 0} =
      System.cmd("git", ["log", "--oneline", "-1"],
        cd: shell.worktree_path,
        stderr_to_stdout: true
      )

    assert String.contains?(log_output, "gitf:"),
           "Expected auto-commit in worktree, got: #{String.trim(log_output)}"

    # Bridge past Tachikoma → SyncQueue
    bridge_to_sync_queue(op.id, shell.id)
    await_sync_idle()

    # Op should be marked as merged
    {:ok, merged_op} = GiTF.Ops.get(op.id)
    assert Map.get(merged_op, :merged_at) != nil, "Op should have merged_at timestamp"

    # Main branch should have the ghost's file
    repo_path = sector.path
    System.cmd("git", ["checkout", "main"], cd: repo_path, stderr_to_stdout: true)
    assert current_branch(repo_path) == "main"

    assert file_on_branch?(repo_path, "auto_merge_result.txt"),
           "File should be present on main after auto_merge"

    # Major was notified
    assert_waggle(subject: "job_merged", timeout: 5_000)
  end

  scenario "pr_branch: ghost changes stay on branch, no merge to main" do
    {:ok, env, sector} = add_sector_with_strategy(env, "pr_branch")
    ensure_sync_queue()

    {:ok, _mission, [op]} =
      Harness.create_quest(env,
        sector_id: sector.id,
        goal: "PR branch test",
        ops: [%{title: "Create a file for PR"}]
      )

    {:ok, ghost} =
      spawn_ghost_with_file(env, op.id, sector.id, "pr_branch_result.txt", "pr branch")

    await({:job_done, op.id}, timeout: 20_000)
    await({:bee_stopped, ghost.id}, timeout: 10_000)

    shell = shell_for_ghost(ghost.id)
    assert shell != nil

    # Verify auto-commit in worktree
    {log_output, 0} =
      System.cmd("git", ["log", "--oneline", "-1"],
        cd: shell.worktree_path,
        stderr_to_stdout: true
      )

    assert String.contains?(log_output, "gitf:")

    # Bridge to SyncQueue
    bridge_to_sync_queue(op.id, shell.id)
    await_sync_idle()

    # Pipeline advanced (op marked as merged)
    {:ok, merged_op} = GiTF.Ops.get(op.id)

    assert Map.get(merged_op, :merged_at) != nil,
           "Op should have merged_at after pr_branch sync"

    # Main should NOT have the file — pr_branch doesn't merge
    repo_path = sector.path
    System.cmd("git", ["checkout", "main"], cd: repo_path, stderr_to_stdout: true)
    assert current_branch(repo_path) == "main"

    refute file_on_branch?(repo_path, "pr_branch_result.txt"),
           "File should NOT be on main for pr_branch strategy"

    # Ghost branch should still exist
    ghost_branch = shell.branch

    assert GiTF.Git.branch_exists?(repo_path, ghost_branch),
           "Ghost branch #{ghost_branch} should still exist"

    assert_waggle(subject: "job_merged", timeout: 5_000)
  end

  scenario "manual: ghost changes committed, no merge or PR attempted" do
    {:ok, env, sector} = add_sector_with_strategy(env, "manual")
    ensure_sync_queue()

    {:ok, _mission, [op]} =
      Harness.create_quest(env,
        sector_id: sector.id,
        goal: "Manual sync test",
        ops: [%{title: "Create a file (manual)"}]
      )

    {:ok, ghost} =
      spawn_ghost_with_file(env, op.id, sector.id, "manual_result.txt", "manual mode")

    await({:job_done, op.id}, timeout: 20_000)
    await({:bee_stopped, ghost.id}, timeout: 10_000)

    shell = shell_for_ghost(ghost.id)
    assert shell != nil

    # Verify auto-commit
    {log_output, 0} =
      System.cmd("git", ["log", "--oneline", "-1"],
        cd: shell.worktree_path,
        stderr_to_stdout: true
      )

    assert String.contains?(log_output, "gitf:")

    # Bridge to SyncQueue
    bridge_to_sync_queue(op.id, shell.id)
    await_sync_idle()

    # Pipeline advances even for manual
    {:ok, merged_op} = GiTF.Ops.get(op.id)
    assert Map.get(merged_op, :merged_at) != nil

    # Main should NOT have the file
    repo_path = sector.path
    System.cmd("git", ["checkout", "main"], cd: repo_path, stderr_to_stdout: true)

    refute file_on_branch?(repo_path, "manual_result.txt"),
           "File should NOT be on main for manual strategy"

    # Ghost branch should exist for manual merge later
    ghost_branch = shell.branch

    assert GiTF.Git.branch_exists?(repo_path, ghost_branch),
           "Ghost branch #{ghost_branch} should exist for manual merge"

    assert_waggle(subject: "job_merged", timeout: 5_000)
  end

  scenario "auto_merge with two ops: both merge to main sequentially" do
    {:ok, env, sector} = add_sector_with_strategy(env, "auto_merge")
    ensure_sync_queue()

    {:ok, _mission, [op1, op2]} =
      Harness.create_quest(env,
        sector_id: sector.id,
        goal: "Multi-op auto-merge test",
        ops: [
          %{title: "Create file A"},
          %{title: "Create file B"}
        ]
      )

    {:ok, ghost1} = spawn_ghost_with_file(env, op1.id, sector.id, "file_a.txt", "from op 1")
    {:ok, ghost2} = spawn_ghost_with_file(env, op2.id, sector.id, "file_b.txt", "from op 2")

    await({:job_done, op1.id}, timeout: 20_000)
    await({:job_done, op2.id}, timeout: 20_000)

    shell1 = shell_for_ghost(ghost1.id)
    shell2 = shell_for_ghost(ghost2.id)

    # Feed both to SyncQueue sequentially
    bridge_to_sync_queue(op1.id, shell1.id)
    Process.sleep(200)
    bridge_to_sync_queue(op2.id, shell2.id)

    # Wait for both to be merged
    await(
      fn ->
        {:ok, j1} = GiTF.Ops.get(op1.id)
        {:ok, j2} = GiTF.Ops.get(op2.id)
        Map.get(j1, :merged_at) != nil and Map.get(j2, :merged_at) != nil
      end, timeout: 30_000, message: "Both ops should be merged")

    # Both files should be on main
    repo_path = sector.path
    System.cmd("git", ["checkout", "main"], cd: repo_path, stderr_to_stdout: true)
    assert file_on_branch?(repo_path, "file_a.txt"), "file_a.txt should be on main"
    assert file_on_branch?(repo_path, "file_b.txt"), "file_b.txt should be on main"
  end
end
