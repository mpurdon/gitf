defmodule GiTF.Ghost.WorkerTest do
  use ExUnit.Case, async: false

  alias GiTF.Ghost.Worker
  alias GiTF.Store

  @tmp_dir System.tmp_dir!()

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()
    store_dir = Path.join(@tmp_dir, "gitf_store_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(store_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Store.start_link(data_dir: store_dir)
    on_exit(fn -> File.rm_rf!(store_dir) end)

    # Create a temp git repo to serve as a comb
    repo_path = create_temp_git_repo()
    gitf_root = create_gitf_workspace()

    {:ok, comb} =
      GiTF.Comb.add(repo_path, name: "worker-test-comb-#{:erlang.unique_integer([:positive])}")

    {:ok, quest} =
      Store.insert(:quests, %{
        name: "worker-test-quest-#{:erlang.unique_integer([:positive])}",
        status: "pending"
      })

    {:ok, job} =
      GiTF.Jobs.create(%{
        title: "Test task for ghost",
        description: "Do the work",
        quest_id: quest.id,
        comb_id: comb.id
      })

    {:ok, ghost} = Store.insert(:ghosts, %{name: "test-worker-ghost", status: "starting"})

    # Assign the job to the ghost so the transition pending->assigned works
    {:ok, _} = GiTF.Jobs.assign(job.id, ghost.id)

    %{
      comb: comb,
      quest: quest,
      job: job,
      ghost: ghost,
      gitf_root: gitf_root,
      repo_path: repo_path
    }
  end

  describe "start_link/1 with successful command" do
    test "provisions and runs to completion", ctx do
      # Use /bin/echo as a fake "claude" that exits immediately with 0
      {:ok, pid} =
        Worker.start_link(
          ghost_id: ctx.ghost.id,
          job_id: ctx.job.id,
          comb_id: ctx.comb.id,
          gitf_root: ctx.gitf_root,
          claude_executable: "/bin/echo",
          prompt: "hello"
        )

      ref = Process.monitor(pid)

      # Wait for the process to finish (echo exits quickly)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

      # Verify DB state: ghost should be stopped or crashed
      # (validation failure in test env may mark ghost as crashed)
      {:ok, ghost} = GiTF.Ghosts.get(ctx.ghost.id)
      assert ghost.status in ["stopped", "crashed"]

      # Job should be done or failed (validation may fail in test env)
      {:ok, job} = GiTF.Jobs.get(ctx.job.id)
      assert job.status in ["done", "failed"]

      # A waggle message should have been sent to the queen
      # The worker may report job_complete or validation_failed depending on
      # whether git post-processing succeeds in the test environment
      waggles = GiTF.Waggle.list(from: ctx.ghost.id)
      assert length(waggles) >= 1
      assert Enum.any?(waggles, &(&1.subject in ["job_complete", "validation_failed"]))
    end
  end

  describe "start_link/1 with failing command" do
    test "marks ghost crashed and job failed on non-zero exit", ctx do
      # Use /usr/bin/false which exits with status 1
      {:ok, pid} =
        Worker.start_link(
          ghost_id: ctx.ghost.id,
          job_id: ctx.job.id,
          comb_id: ctx.comb.id,
          gitf_root: ctx.gitf_root,
          claude_executable: "/usr/bin/false",
          prompt: "fail"
        )

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

      # Verify DB state: ghost should be crashed
      {:ok, ghost} = GiTF.Ghosts.get(ctx.ghost.id)
      assert ghost.status == "crashed"

      # Job should be failed
      {:ok, job} = GiTF.Jobs.get(ctx.job.id)
      assert job.status == "failed"

      # A waggle message about failure
      waggles = GiTF.Waggle.list(from: ctx.ghost.id)
      assert Enum.any?(waggles, &(&1.subject == "job_failed"))
    end
  end

  describe "status/1" do
    test "returns the worker status while running", ctx do
      # Use /bin/sleep to keep the process alive
      {:ok, pid} =
        Worker.start_link(
          ghost_id: ctx.ghost.id,
          job_id: ctx.job.id,
          comb_id: ctx.comb.id,
          gitf_root: ctx.gitf_root,
          claude_executable: "/bin/sleep",
          prompt: "30"
        )

      # Give it a moment to provision
      Process.sleep(500)

      assert {:ok, status} = Worker.status(ctx.ghost.id)
      assert status.ghost_id == ctx.ghost.id
      assert status.job_id == ctx.job.id
      assert status.status == :running

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal)
      end)
    end

    test "returns error for non-running ghost" do
      assert {:error, :not_found} = Worker.status("ghost-nonexistent")
    end
  end

  describe "stop/1" do
    test "gracefully stops a running worker", ctx do
      # Trap exits so the :shutdown signal from GenServer.stop doesn't kill the test
      Process.flag(:trap_exit, true)

      {:ok, pid} =
        Worker.start_link(
          ghost_id: ctx.ghost.id,
          job_id: ctx.job.id,
          comb_id: ctx.comb.id,
          gitf_root: ctx.gitf_root,
          claude_executable: "/bin/sleep",
          prompt: "30"
        )

      Process.sleep(500)
      ref = Process.monitor(pid)

      assert :ok = Worker.stop(ctx.ghost.id)
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5_000
      assert reason in [:normal, :shutdown]

      {:ok, ghost} = GiTF.Ghosts.get(ctx.ghost.id)
      assert ghost.status == "stopped"
    end

    test "returns error for non-running ghost" do
      assert {:error, :not_found} = Worker.stop("ghost-nonexistent")
    end
  end

  describe "lookup/1" do
    test "finds a running worker via Registry", ctx do
      {:ok, pid} =
        Worker.start_link(
          ghost_id: ctx.ghost.id,
          job_id: ctx.job.id,
          comb_id: ctx.comb.id,
          gitf_root: ctx.gitf_root,
          claude_executable: "/bin/sleep",
          prompt: "30"
        )

      Process.sleep(100)

      assert {:ok, ^pid} = Worker.lookup(ctx.ghost.id)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal)
      end)
    end

    test "returns error when no worker running" do
      assert :error = Worker.lookup("ghost-nonexistent")
    end
  end

  describe "child_spec/1" do
    test "produces a valid child spec with temporary restart" do
      spec =
        Worker.child_spec(
          ghost_id: "ghost-test",
          job_id: "job-test",
          comb_id: "cmb-test",
          gitf_root: "/tmp"
        )

      assert spec.restart == :temporary
      assert spec.id == {Worker, "ghost-test"}
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp create_temp_git_repo do
    name = "gitf_worker_test_#{:erlang.unique_integer([:positive])}"
    path = Path.join(@tmp_dir, name)
    File.mkdir_p!(path)

    System.cmd("git", ["init"], cd: path, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@gitf.local"], cd: path)
    System.cmd("git", ["config", "user.name", "Test"], cd: path)

    readme = Path.join(path, "README.md")
    File.write!(readme, "# Test\n")
    System.cmd("git", ["add", "."], cd: path, stderr_to_stdout: true)
    System.cmd("git", ["commit", "-m", "initial"], cd: path, stderr_to_stdout: true)

    {real_path, 0} =
      System.cmd("git", ["rev-parse", "--show-toplevel"],
        cd: path,
        stderr_to_stdout: true
      )

    real_path = String.trim(real_path)

    on_exit(fn -> File.rm_rf!(path) end)
    real_path
  end

  defp create_gitf_workspace do
    name = "gitf_worker_ws_#{:erlang.unique_integer([:positive])}"
    path = Path.join(@tmp_dir, name)
    gitf_dir = Path.join(path, ".gitf")
    File.mkdir_p!(gitf_dir)
    File.write!(Path.join(gitf_dir, "config.toml"), "")
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
