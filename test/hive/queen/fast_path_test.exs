defmodule Hive.Queen.FastPathTest do
  use ExUnit.Case, async: false

  alias Hive.Queen.FastPath
  alias Hive.Store

  setup do
    Hive.Test.StoreHelper.ensure_infrastructure()
    tmp_dir = Path.join(System.tmp_dir!(), "fast_path_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)
    Hive.Test.StoreHelper.stop_store()
    {:ok, _} = Store.start_link(data_dir: tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, comb} = Store.insert(:combs, %{name: "test-comb", path: "/tmp/test"})

    {:ok, quest} =
      Store.insert(:quests, %{
        name: "simple-quest",
        goal: "Fix typo in README",
        comb_id: comb.id,
        status: "pending",
        current_phase: "pending",
        artifacts: %{},
        phase_jobs: %{},
        research_summary: nil,
        implementation_plan: nil
      })

    %{quest: quest, comb: comb}
  end

  describe "eligible?/1" do
    test "returns true for simple typo fix", %{quest: quest} do
      assert FastPath.eligible?(quest)
    end

    test "returns true for doc update" do
      quest = %{goal: "Update changelog for v1.2.3", artifacts: %{}}
      assert FastPath.eligible?(quest)
    end

    test "returns true for version bump" do
      quest = %{goal: "Bump version to 1.0.0", artifacts: %{}}
      assert FastPath.eligible?(quest)
    end

    test "returns true for rename" do
      quest = %{goal: "Rename helper function from foo to bar", artifacts: %{}}
      assert FastPath.eligible?(quest)
    end

    test "returns false for complex goals with migration keyword" do
      quest = %{goal: "Add database migration for user auth", artifacts: %{}}
      refute FastPath.eligible?(quest)
    end

    test "returns false for security-related changes" do
      quest = %{goal: "Fix security vulnerability in authentication", artifacts: %{}}
      refute FastPath.eligible?(quest)
    end

    test "returns false for deploy-related changes" do
      quest = %{goal: "Fix deploy pipeline for production", artifacts: %{}}
      refute FastPath.eligible?(quest)
    end

    test "returns false for long goals" do
      long_goal = String.duplicate("Fix the typo in the documentation. ", 20)
      quest = %{goal: long_goal, artifacts: %{}}
      refute FastPath.eligible?(quest)
    end

    test "returns false when artifacts already exist" do
      quest = %{goal: "Fix typo in README", artifacts: %{"research" => %{}}}
      refute FastPath.eligible?(quest)
    end

    test "returns false without simple indicators" do
      quest = %{goal: "Implement new user registration flow", artifacts: %{}}
      refute FastPath.eligible?(quest)
    end

    test "returns false for multi-file references" do
      quest = %{
        goal: "Fix typo in lib/foo.ex lib/bar.ex lib/baz.ex",
        artifacts: %{}
      }

      refute FastPath.eligible?(quest)
    end
  end

  describe "execute/1" do
    test "transitions quest to implementation and creates job", %{quest: quest} do
      {:ok, phase} = FastPath.execute(quest.id)

      assert phase == "implementation"

      # Verify job was created
      jobs = Hive.Jobs.list(quest_id: quest.id)
      assert length(jobs) == 1
      assert hd(jobs).title == quest.goal
      refute hd(jobs).phase_job
    end

    test "returns error for non-existent quest" do
      {:error, :not_found} = FastPath.execute("non-existent")
    end
  end
end
