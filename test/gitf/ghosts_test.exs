defmodule GiTF.GhostsTest do
  use ExUnit.Case, async: false

  alias GiTF.Ghosts
  alias GiTF.Store

  @tmp_dir System.tmp_dir!()

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    # Ensure CombSupervisor is running (may have been killed by prior tests)
    unless Process.whereis(GiTF.CombSupervisor) do
      DynamicSupervisor.start_link(strategy: :one_for_one, name: GiTF.CombSupervisor)
    end

    store_dir = Path.join(@tmp_dir, "gitf_store_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(store_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Store.start_link(data_dir: store_dir)
    on_exit(fn -> File.rm_rf!(store_dir) end)

    repo_path = create_temp_git_repo()
    gitf_root = create_gitf_workspace()

    {:ok, comb} =
      GiTF.Comb.add(repo_path, name: "ghosts-test-comb-#{:erlang.unique_integer([:positive])}")

    {:ok, quest} =
      Store.insert(:quests, %{
        name: "ghosts-test-quest-#{:erlang.unique_integer([:positive])}",
        status: "pending"
      })

    {:ok, job} =
      GiTF.Jobs.create(%{
        title: "Bees test task",
        quest_id: quest.id,
        comb_id: comb.id
      })

    %{comb: comb, quest: quest, job: job, gitf_root: gitf_root}
  end

  describe "spawn/4" do
    test "creates a ghost record, assigns the job, and starts a worker", ctx do
      assert {:ok, ghost} =
               Ghosts.spawn(ctx.job.id, ctx.comb.id, ctx.gitf_root,
                 name: "spawned-ghost",
                 claude_executable: "/bin/echo",
                 prompt: "hello"
               )

      assert ghost.name == "spawned-ghost"
      assert String.starts_with?(ghost.id, "ghost-")

      # Job should be assigned to this ghost
      {:ok, job} = GiTF.Jobs.get(ctx.job.id)
      assert job.ghost_id == ghost.id
      assert job.status == "assigned"

      # Worker should have started (wait for it to finish since echo exits fast)
      Process.sleep(1_000)

      # After echo finishes, ghost should be stopped
      {:ok, updated_bee} = Ghosts.get(ghost.id)
      assert updated_bee.status == "stopped"
    end

    test "auto-generates a name if not provided", ctx do
      assert {:ok, ghost} =
               Ghosts.spawn(ctx.job.id, ctx.comb.id, ctx.gitf_root,
                 claude_executable: "/bin/echo",
                 prompt: "auto-name"
               )

      assert is_binary(ghost.name)
      assert String.length(ghost.name) > 0

      # Wait for process to finish
      Process.sleep(500)
    end
  end

  describe "list/1" do
    test "lists all ghosts" do
      {:ok, _} = Store.insert(:ghosts, %{name: "listed-ghost", status: "idle"})

      ghosts = Ghosts.list()
      assert length(ghosts) >= 1
    end

    test "filters by status" do
      {:ok, _} = Store.insert(:ghosts, %{name: "idle-ghost", status: "idle"})
      {:ok, _} = Store.insert(:ghosts, %{name: "working-ghost", status: "working"})

      idle = Ghosts.list(status: "idle")
      assert Enum.all?(idle, &(&1.status == "idle"))

      working = Ghosts.list(status: "working")
      assert Enum.all?(working, &(&1.status == "working"))
    end
  end

  describe "get/1" do
    test "retrieves a ghost by ID" do
      {:ok, created} = Store.insert(:ghosts, %{name: "get-test-ghost", status: "starting"})

      assert {:ok, found} = Ghosts.get(created.id)
      assert found.id == created.id
    end

    test "returns error for unknown ID" do
      assert {:error, :not_found} = Ghosts.get("ghost-000000")
    end
  end

  describe "stop/1" do
    test "stops a running worker", ctx do
      {:ok, ghost} =
        Ghosts.spawn(ctx.job.id, ctx.comb.id, ctx.gitf_root,
          name: "stoppable-ghost",
          claude_executable: "/bin/sleep",
          prompt: "30"
        )

      Process.sleep(500)

      assert :ok = Ghosts.stop(ghost.id)
      Process.sleep(200)

      {:ok, stopped_bee} = Ghosts.get(ghost.id)
      assert stopped_bee.status == "stopped"
    end

    test "returns error for non-running ghost" do
      assert {:error, :not_found} = Ghosts.stop("ghost-nonexistent")
    end
  end

  describe "revive/3" do
    test "creates new ghost in dead ghost's worktree", ctx do
      # Spawn a ghost and let it finish (echo exits immediately)
      {:ok, ghost} =
        Ghosts.spawn(ctx.job.id, ctx.comb.id, ctx.gitf_root,
          name: "doomed-ghost",
          claude_executable: "/bin/echo",
          prompt: "hello"
        )

      Process.sleep(1_000)

      # Bee should be stopped now; mark it as crashed for revive testing
      {:ok, stopped_bee} = Ghosts.get(ghost.id)
      Store.put(:ghosts, %{stopped_bee | status: "crashed"})

      # The job was completed by the worker — mark it failed so revive transition works
      {:ok, job} = GiTF.Jobs.get(ctx.job.id)
      Store.put(:jobs, %{job | status: "failed"})

      # Revive
      {:ok, new_bee} = Ghosts.revive(ghost.id, ctx.gitf_root, claude_executable: "/bin/echo")

      assert new_ghost.id != ghost.id
      assert new_bee.job_id == ghost.job_id

      # Cell should be reassigned to new ghost
      cell = Store.find_one(:cells, fn c -> c.ghost_id == new_ghost.id and c.status == "active" end)
      assert cell != nil

      Process.sleep(1_000)
    end

    test "fails for active ghost", ctx do
      {:ok, ghost} =
        Store.insert(:ghosts, %{name: "active-ghost", status: "working", job_id: ctx.job.id})

      assert {:error, :bee_still_active} = Ghosts.revive(ghost.id, ctx.gitf_root)
    end

    test "fails with no cell", ctx do
      {:ok, ghost} =
        Store.insert(:ghosts, %{name: "no-cell-ghost", status: "crashed", job_id: ctx.job.id})

      assert {:error, :no_active_cell} = Ghosts.revive(ghost.id, ctx.gitf_root)
    end

    test "revive transitions failed job to running", ctx do
      # Spawn and let it finish
      {:ok, ghost} =
        Ghosts.spawn(ctx.job.id, ctx.comb.id, ctx.gitf_root,
          name: "revive-job-test",
          claude_executable: "/bin/echo",
          prompt: "hello"
        )

      Process.sleep(1_000)

      {:ok, stopped_bee} = Ghosts.get(ghost.id)
      Store.put(:ghosts, %{stopped_bee | status: "crashed"})

      {:ok, job} = GiTF.Jobs.get(ctx.job.id)
      Store.put(:jobs, %{job | status: "failed"})

      {:ok, new_bee} = Ghosts.revive(ghost.id, ctx.gitf_root, claude_executable: "/bin/echo")

      {:ok, updated_job} = GiTF.Jobs.get(ctx.job.id)
      assert updated_job.status == "running"
      assert updated_job.ghost_id == new_ghost.id

      Process.sleep(1_000)
    end

    test "revive leaves done job alone", ctx do
      # Spawn and let it complete
      {:ok, ghost} =
        Ghosts.spawn(ctx.job.id, ctx.comb.id, ctx.gitf_root,
          name: "done-job-test",
          claude_executable: "/bin/echo",
          prompt: "hello"
        )

      Process.sleep(1_000)

      {:ok, stopped_bee} = Ghosts.get(ghost.id)
      Store.put(:ghosts, %{stopped_bee | status: "crashed"})

      # Job is "done" from the worker completing — leave it done
      {:ok, job} = GiTF.Jobs.get(ctx.job.id)
      assert job.status == "done"

      {:ok, _new_bee} = Ghosts.revive(ghost.id, ctx.gitf_root, claude_executable: "/bin/echo")

      {:ok, still_done_job} = GiTF.Jobs.get(ctx.job.id)
      assert still_done_job.status == "done"

      Process.sleep(1_000)
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp create_temp_git_repo do
    name = "gitf_bees_test_#{:erlang.unique_integer([:positive])}"
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
    name = "gitf_bees_ws_#{:erlang.unique_integer([:positive])}"
    path = Path.join(@tmp_dir, name)
    gitf_dir = Path.join(path, ".gitf")
    File.mkdir_p!(gitf_dir)
    File.write!(Path.join(gitf_dir, "config.toml"), "")
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
