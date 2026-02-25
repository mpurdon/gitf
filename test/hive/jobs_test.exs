defmodule Hive.JobsTest do
  use ExUnit.Case, async: false

  alias Hive.Jobs
  alias Hive.Store

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "hive_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    if Process.whereis(Hive.Store), do: GenServer.stop(Hive.Store)
    {:ok, _} = Hive.Store.start_link(data_dir: tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, comb} =
      Store.insert(:combs, %{name: "jobs-test-comb-#{:erlang.unique_integer([:positive])}"})

    {:ok, quest} =
      Store.insert(:quests, %{
        name: "jobs-test-quest-#{:erlang.unique_integer([:positive])}",
        status: "pending"
      })

    %{comb: comb, quest: quest}
  end

  defp create_job(quest, comb, attrs \\ %{}) do
    default = %{
      title: "Test job #{:erlang.unique_integer([:positive])}",
      quest_id: quest.id,
      comb_id: comb.id
    }

    Jobs.create(Map.merge(default, attrs))
  end

  defp create_bee(name \\ nil) do
    name = name || "test-bee-#{:erlang.unique_integer([:positive])}"
    {:ok, bee} = Store.insert(:bees, %{name: name, status: "starting"})
    bee
  end

  describe "create/1" do
    test "creates a job with valid attributes", %{quest: quest, comb: comb} do
      assert {:ok, job} = create_job(quest, comb, %{title: "Build feature"})
      assert job.title == "Build feature"
      assert job.status == "pending"
      assert job.quest_id == quest.id
      assert job.comb_id == comb.id
      assert String.starts_with?(job.id, "job-")
    end

    test "requires title", %{quest: quest, comb: comb} do
      assert {:error, {:missing_fields, [:title]}} =
               Jobs.create(%{quest_id: quest.id, comb_id: comb.id})
    end

    test "accepts optional description", %{quest: quest, comb: comb} do
      assert {:ok, job} =
               create_job(quest, comb, %{title: "Work", description: "Detailed instructions"})

      assert job.description == "Detailed instructions"
    end
  end

  describe "get/1" do
    test "retrieves a job by ID", %{quest: quest, comb: comb} do
      {:ok, created} = create_job(quest, comb)
      assert {:ok, found} = Jobs.get(created.id)
      assert found.id == created.id
    end

    test "returns error for unknown ID" do
      assert {:error, :not_found} = Jobs.get("job-000000")
    end
  end

  describe "list/1" do
    test "returns all jobs", %{quest: quest, comb: comb} do
      {:ok, _} = create_job(quest, comb)
      {:ok, _} = create_job(quest, comb)

      jobs = Jobs.list()
      assert length(jobs) >= 2
    end

    test "filters by quest_id", %{quest: quest, comb: comb} do
      {:ok, _} = create_job(quest, comb)

      {:ok, other_quest} =
        Store.insert(:quests, %{
          name: "other-quest-#{:erlang.unique_integer([:positive])}",
          status: "pending"
        })

      {:ok, _} = create_job(other_quest, comb)

      jobs = Jobs.list(quest_id: quest.id)
      assert Enum.all?(jobs, &(&1.quest_id == quest.id))
    end

    test "filters by status", %{quest: quest, comb: comb} do
      {:ok, _} = create_job(quest, comb)

      pending = Jobs.list(status: "pending")
      assert length(pending) >= 1

      done = Jobs.list(status: "done")
      assert Enum.all?(done, &(&1.status == "done"))
    end
  end

  describe "status transitions" do
    test "pending -> assigned via assign/2", %{quest: quest, comb: comb} do
      bee = create_bee()
      {:ok, job} = create_job(quest, comb)
      assert job.status == "pending"

      assert {:ok, assigned} = Jobs.assign(job.id, bee.id)
      assert assigned.status == "assigned"
      assert assigned.bee_id == bee.id
    end

    test "assigned -> running via start/1", %{quest: quest, comb: comb} do
      bee = create_bee()
      {:ok, job} = create_job(quest, comb)
      {:ok, _} = Jobs.assign(job.id, bee.id)

      assert {:ok, running} = Jobs.start(job.id)
      assert running.status == "running"
    end

    test "running -> done via complete/1", %{quest: quest, comb: comb} do
      bee = create_bee()
      {:ok, job} = create_job(quest, comb)
      {:ok, _} = Jobs.assign(job.id, bee.id)
      {:ok, _} = Jobs.start(job.id)

      assert {:ok, done} = Jobs.complete(job.id)
      assert done.status == "done"
    end

    test "running -> failed via fail/1", %{quest: quest, comb: comb} do
      bee = create_bee()
      {:ok, job} = create_job(quest, comb)
      {:ok, _} = Jobs.assign(job.id, bee.id)
      {:ok, _} = Jobs.start(job.id)

      assert {:ok, failed} = Jobs.fail(job.id)
      assert failed.status == "failed"
    end

    test "pending -> blocked via block/1", %{quest: quest, comb: comb} do
      {:ok, job} = create_job(quest, comb)

      assert {:ok, blocked} = Jobs.block(job.id)
      assert blocked.status == "blocked"
    end

    test "running -> blocked via block/1", %{quest: quest, comb: comb} do
      bee = create_bee()
      {:ok, job} = create_job(quest, comb)
      {:ok, _} = Jobs.assign(job.id, bee.id)
      {:ok, _} = Jobs.start(job.id)

      assert {:ok, blocked} = Jobs.block(job.id)
      assert blocked.status == "blocked"
    end

    test "blocked -> pending via unblock/1", %{quest: quest, comb: comb} do
      {:ok, job} = create_job(quest, comb)
      {:ok, _} = Jobs.block(job.id)

      assert {:ok, unblocked} = Jobs.unblock(job.id)
      assert unblocked.status == "pending"
    end

    test "failed -> pending via reset/1", %{quest: quest, comb: comb} do
      bee = create_bee()
      {:ok, job} = create_job(quest, comb)
      {:ok, _} = Jobs.assign(job.id, bee.id)
      {:ok, _} = Jobs.start(job.id)
      {:ok, _} = Jobs.fail(job.id)

      assert {:ok, reset} = Jobs.reset(job.id)
      assert reset.status == "pending"
      assert reset.bee_id == nil
    end

    test "reset/2 appends feedback to description", %{quest: quest, comb: comb} do
      bee = create_bee()
      {:ok, job} = create_job(quest, comb, %{description: "Original task"})
      {:ok, _} = Jobs.assign(job.id, bee.id)
      {:ok, _} = Jobs.start(job.id)
      {:ok, _} = Jobs.fail(job.id)

      assert {:ok, reset} = Jobs.reset(job.id, "Validation failed: X is missing")
      assert reset.status == "pending"
      assert String.contains?(reset.description, "Original task")
      assert String.contains?(reset.description, "## Feedback from previous attempt:")
      assert String.contains?(reset.description, "Validation failed: X is missing")
    end
  end

  describe "invalid transitions" do
    test "cannot assign an already assigned job", %{quest: quest, comb: comb} do
      bee1 = create_bee()
      bee2 = create_bee()
      {:ok, job} = create_job(quest, comb)
      {:ok, _} = Jobs.assign(job.id, bee1.id)

      assert {:error, :invalid_transition} = Jobs.assign(job.id, bee2.id)
    end

    test "cannot start a pending job", %{quest: quest, comb: comb} do
      {:ok, job} = create_job(quest, comb)
      assert {:error, :invalid_transition} = Jobs.start(job.id)
    end

    test "cannot complete a pending job", %{quest: quest, comb: comb} do
      {:ok, job} = create_job(quest, comb)
      assert {:error, :invalid_transition} = Jobs.complete(job.id)
    end

    test "cannot fail a pending job", %{quest: quest, comb: comb} do
      {:ok, job} = create_job(quest, comb)
      assert {:error, :invalid_transition} = Jobs.fail(job.id)
    end

    test "cannot unblock a pending job", %{quest: quest, comb: comb} do
      {:ok, job} = create_job(quest, comb)
      assert {:error, :invalid_transition} = Jobs.unblock(job.id)
    end

    test "cannot block a done job", %{quest: quest, comb: comb} do
      bee = create_bee()
      {:ok, job} = create_job(quest, comb)
      {:ok, _} = Jobs.assign(job.id, bee.id)
      {:ok, _} = Jobs.start(job.id)
      {:ok, _} = Jobs.complete(job.id)

      assert {:error, :invalid_transition} = Jobs.block(job.id)
    end

    test "cannot reset a pending job", %{quest: quest, comb: comb} do
      {:ok, job} = create_job(quest, comb)
      assert {:error, :invalid_transition} = Jobs.reset(job.id)
    end

    test "cannot reset a running job", %{quest: quest, comb: comb} do
      bee = create_bee()
      {:ok, job} = create_job(quest, comb)
      {:ok, _} = Jobs.assign(job.id, bee.id)
      {:ok, _} = Jobs.start(job.id)

      assert {:error, :invalid_transition} = Jobs.reset(job.id)
    end
  end
end
