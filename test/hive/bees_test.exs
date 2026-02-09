defmodule Hive.BeesTest do
  use ExUnit.Case, async: false

  alias Hive.Bees
  alias Hive.Store

  @tmp_dir System.tmp_dir!()

  setup do
    store_dir = Path.join(@tmp_dir, "hive_store_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(store_dir)
    if Process.whereis(Hive.Store), do: GenServer.stop(Hive.Store)
    {:ok, _} = Hive.Store.start_link(data_dir: store_dir)
    on_exit(fn -> File.rm_rf!(store_dir) end)

    repo_path = create_temp_git_repo()
    hive_root = create_hive_workspace()

    {:ok, comb} =
      Hive.Comb.add(repo_path, name: "bees-test-comb-#{:erlang.unique_integer([:positive])}")

    {:ok, quest} =
      Store.insert(:quests, %{
        name: "bees-test-quest-#{:erlang.unique_integer([:positive])}",
        status: "pending"
      })

    {:ok, job} =
      Hive.Jobs.create(%{
        title: "Bees test task",
        quest_id: quest.id,
        comb_id: comb.id
      })

    %{comb: comb, quest: quest, job: job, hive_root: hive_root}
  end

  describe "spawn/4" do
    test "creates a bee record, assigns the job, and starts a worker", ctx do
      assert {:ok, bee} =
               Bees.spawn(ctx.job.id, ctx.comb.id, ctx.hive_root,
                 name: "spawned-bee",
                 claude_executable: "/bin/echo",
                 prompt: "hello"
               )

      assert bee.name == "spawned-bee"
      assert String.starts_with?(bee.id, "bee-")

      # Job should be assigned to this bee
      {:ok, job} = Hive.Jobs.get(ctx.job.id)
      assert job.bee_id == bee.id
      assert job.status == "assigned"

      # Worker should have started (wait for it to finish since echo exits fast)
      Process.sleep(1_000)

      # After echo finishes, bee should be stopped
      {:ok, updated_bee} = Bees.get(bee.id)
      assert updated_bee.status == "stopped"
    end

    test "auto-generates a name if not provided", ctx do
      assert {:ok, bee} =
               Bees.spawn(ctx.job.id, ctx.comb.id, ctx.hive_root,
                 claude_executable: "/bin/echo",
                 prompt: "auto-name"
               )

      assert is_binary(bee.name)
      assert String.length(bee.name) > 0

      # Wait for process to finish
      Process.sleep(500)
    end
  end

  describe "list/1" do
    test "lists all bees" do
      {:ok, _} = Store.insert(:bees, %{name: "listed-bee", status: "idle"})

      bees = Bees.list()
      assert length(bees) >= 1
    end

    test "filters by status" do
      {:ok, _} = Store.insert(:bees, %{name: "idle-bee", status: "idle"})
      {:ok, _} = Store.insert(:bees, %{name: "working-bee", status: "working"})

      idle = Bees.list(status: "idle")
      assert Enum.all?(idle, &(&1.status == "idle"))

      working = Bees.list(status: "working")
      assert Enum.all?(working, &(&1.status == "working"))
    end
  end

  describe "get/1" do
    test "retrieves a bee by ID" do
      {:ok, created} = Store.insert(:bees, %{name: "get-test-bee", status: "starting"})

      assert {:ok, found} = Bees.get(created.id)
      assert found.id == created.id
    end

    test "returns error for unknown ID" do
      assert {:error, :not_found} = Bees.get("bee-000000")
    end
  end

  describe "stop/1" do
    test "stops a running worker", ctx do
      {:ok, bee} =
        Bees.spawn(ctx.job.id, ctx.comb.id, ctx.hive_root,
          name: "stoppable-bee",
          claude_executable: "/bin/sleep",
          prompt: "30"
        )

      Process.sleep(500)

      assert :ok = Bees.stop(bee.id)
      Process.sleep(200)

      {:ok, stopped_bee} = Bees.get(bee.id)
      assert stopped_bee.status == "stopped"
    end

    test "returns error for non-running bee" do
      assert {:error, :not_found} = Bees.stop("bee-nonexistent")
    end
  end

  describe "revive/3" do
    test "creates new bee in dead bee's worktree", ctx do
      # Spawn a bee and let it finish (echo exits immediately)
      {:ok, bee} =
        Bees.spawn(ctx.job.id, ctx.comb.id, ctx.hive_root,
          name: "doomed-bee",
          claude_executable: "/bin/echo",
          prompt: "hello"
        )

      Process.sleep(1_000)

      # Bee should be stopped now; mark it as crashed for revive testing
      {:ok, stopped_bee} = Bees.get(bee.id)
      Store.put(:bees, %{stopped_bee | status: "crashed"})

      # The job was completed by the worker — mark it failed so revive transition works
      {:ok, job} = Hive.Jobs.get(ctx.job.id)
      Store.put(:jobs, %{job | status: "failed"})

      # Revive
      {:ok, new_bee} = Bees.revive(bee.id, ctx.hive_root, claude_executable: "/bin/echo")

      assert new_bee.id != bee.id
      assert new_bee.job_id == bee.job_id

      # Cell should be reassigned to new bee
      cell = Store.find_one(:cells, fn c -> c.bee_id == new_bee.id and c.status == "active" end)
      assert cell != nil

      Process.sleep(1_000)
    end

    test "fails for active bee", ctx do
      {:ok, bee} = Store.insert(:bees, %{name: "active-bee", status: "working", job_id: ctx.job.id})
      assert {:error, :bee_still_active} = Bees.revive(bee.id, ctx.hive_root)
    end

    test "fails with no cell", ctx do
      {:ok, bee} = Store.insert(:bees, %{name: "no-cell-bee", status: "crashed", job_id: ctx.job.id})
      assert {:error, :no_active_cell} = Bees.revive(bee.id, ctx.hive_root)
    end

    test "revive transitions failed job to running", ctx do
      # Spawn and let it finish
      {:ok, bee} =
        Bees.spawn(ctx.job.id, ctx.comb.id, ctx.hive_root,
          name: "revive-job-test",
          claude_executable: "/bin/echo",
          prompt: "hello"
        )

      Process.sleep(1_000)

      {:ok, stopped_bee} = Bees.get(bee.id)
      Store.put(:bees, %{stopped_bee | status: "crashed"})

      {:ok, job} = Hive.Jobs.get(ctx.job.id)
      Store.put(:jobs, %{job | status: "failed"})

      {:ok, new_bee} = Bees.revive(bee.id, ctx.hive_root, claude_executable: "/bin/echo")

      {:ok, updated_job} = Hive.Jobs.get(ctx.job.id)
      assert updated_job.status == "running"
      assert updated_job.bee_id == new_bee.id

      Process.sleep(1_000)
    end

    test "revive leaves done job alone", ctx do
      # Spawn and let it complete
      {:ok, bee} =
        Bees.spawn(ctx.job.id, ctx.comb.id, ctx.hive_root,
          name: "done-job-test",
          claude_executable: "/bin/echo",
          prompt: "hello"
        )

      Process.sleep(1_000)

      {:ok, stopped_bee} = Bees.get(bee.id)
      Store.put(:bees, %{stopped_bee | status: "crashed"})

      # Job is "done" from the worker completing — leave it done
      {:ok, job} = Hive.Jobs.get(ctx.job.id)
      assert job.status == "done"

      {:ok, _new_bee} = Bees.revive(bee.id, ctx.hive_root, claude_executable: "/bin/echo")

      {:ok, still_done_job} = Hive.Jobs.get(ctx.job.id)
      assert still_done_job.status == "done"

      Process.sleep(1_000)
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp create_temp_git_repo do
    name = "hive_bees_test_#{:erlang.unique_integer([:positive])}"
    path = Path.join(@tmp_dir, name)
    File.mkdir_p!(path)

    System.cmd("git", ["init"], cd: path, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@hive.local"], cd: path)
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

  defp create_hive_workspace do
    name = "hive_bees_ws_#{:erlang.unique_integer([:positive])}"
    path = Path.join(@tmp_dir, name)
    File.mkdir_p!(Path.join(path, ".hive"))
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
