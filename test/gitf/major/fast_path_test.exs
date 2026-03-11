defmodule GiTF.Major.FastPathTest do
  use ExUnit.Case, async: false

  alias GiTF.Major.FastPath
  alias GiTF.Archive

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()
    tmp_dir = Path.join(System.tmp_dir!(), "fast_path_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = Archive.start_link(data_dir: tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, sector} = Archive.insert(:sectors, %{name: "test-sector", path: "/tmp/test"})

    {:ok, mission} =
      Archive.insert(:missions, %{
        name: "simple-mission",
        goal: "Fix typo in README",
        sector_id: sector.id,
        status: "pending",
        current_phase: "pending",
        artifacts: %{},
        phase_jobs: %{},
        research_summary: nil,
        implementation_plan: nil
      })

    %{mission: mission, sector: sector}
  end

  describe "eligible?/1" do
    test "returns true for simple typo fix", %{mission: mission} do
      assert FastPath.eligible?(mission)
    end

    test "returns true for doc update" do
      mission = %{goal: "Update changelog for v1.2.3", artifacts: %{}}
      assert FastPath.eligible?(mission)
    end

    test "returns true for version bump" do
      mission = %{goal: "Bump version to 1.0.0", artifacts: %{}}
      assert FastPath.eligible?(mission)
    end

    test "returns true for rename" do
      mission = %{goal: "Rename helper function from foo to bar", artifacts: %{}}
      assert FastPath.eligible?(mission)
    end

    test "returns false for complex goals with migration keyword" do
      mission = %{goal: "Add database migration for user auth", artifacts: %{}}
      refute FastPath.eligible?(mission)
    end

    test "returns false for security-related changes" do
      mission = %{goal: "Fix security vulnerability in authentication", artifacts: %{}}
      refute FastPath.eligible?(mission)
    end

    test "returns false for deploy-related changes" do
      mission = %{goal: "Fix deploy pipeline for production", artifacts: %{}}
      refute FastPath.eligible?(mission)
    end

    test "returns false for long goals" do
      long_goal = String.duplicate("Fix the typo in the documentation. ", 20)
      mission = %{goal: long_goal, artifacts: %{}}
      refute FastPath.eligible?(mission)
    end

    test "returns false when artifacts already exist" do
      mission = %{goal: "Fix typo in README", artifacts: %{"research" => %{}}}
      refute FastPath.eligible?(mission)
    end

    test "returns false without simple indicators" do
      mission = %{goal: "Implement new user registration flow", artifacts: %{}}
      refute FastPath.eligible?(mission)
    end

    test "returns false for multi-file references" do
      mission = %{
        goal: "Fix typo in lib/foo.ex lib/bar.ex lib/baz.ex",
        artifacts: %{}
      }

      refute FastPath.eligible?(mission)
    end
  end

  describe "execute/1" do
    test "transitions mission to implementation and creates op", %{mission: mission} do
      {:ok, phase} = FastPath.execute(mission.id)

      assert phase == "implementation"

      # Verify op was created
      ops = GiTF.Ops.list(mission_id: mission.id)
      assert length(ops) == 1
      assert hd(ops).title == mission.goal
      refute hd(ops).phase_job
    end

    test "returns error for non-existent mission" do
      {:error, :not_found} = FastPath.execute("non-existent")
    end
  end
end
