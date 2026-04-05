defmodule GiTF.Major.FastPathTest do
  use GiTF.StoreCase

  alias GiTF.Major.FastPath
  alias GiTF.Archive

  setup do
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

    test "returns true for security-related bug fix (not multi-system)" do
      mission = %{goal: "Fix security vulnerability in authentication", artifacts: %{}}
      assert FastPath.eligible?(mission)
    end

    test "returns false for multi-system infrastructure changes" do
      mission = %{
        goal: "Redesign distributed infrastructure for multi-service deployment",
        artifacts: %{}
      }

      refute FastPath.eligible?(mission)
    end

    test "returns false for long goals (spec-length)" do
      long_goal =
        String.duplicate("Implement the full user registration flow with validation. ", 25)

      mission = %{goal: long_goal, artifacts: %{}}
      refute FastPath.eligible?(mission)
    end

    test "returns false when artifacts already exist" do
      mission = %{goal: "Fix typo in README", artifacts: %{"research" => %{}}}
      refute FastPath.eligible?(mission)
    end

    test "returns true for focused feature without complex keywords" do
      mission = %{goal: "Implement new user registration flow", artifacts: %{}}
      assert FastPath.eligible?(mission)
    end

    test "returns false for excessive file references" do
      mission = %{
        goal: "Fix typo in lib/foo.ex lib/bar.ex lib/baz.ex lib/qux.ex lib/quux.ex lib/corge.ex",
        artifacts: %{}
      }

      refute FastPath.eligible?(mission)
    end

    test "force: true bypasses eligibility checks" do
      mission = %{goal: "Redesign distributed infrastructure", artifacts: %{}}
      refute FastPath.eligible?(mission)
      assert FastPath.eligible?(mission, force: true)
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
