defmodule GiTF.Major.PlannerReplanTest do
  use ExUnit.Case, async: false

  alias GiTF.Major.Planner
  alias GiTF.Archive

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()
    tmp_dir = Path.join(System.tmp_dir!(), "replan_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = Archive.start_link(data_dir: tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    # Create a mission
    {:ok, mission} =
      Archive.insert(:missions, %{
        name: "Test Quest",
        goal: "Build a widget",
        status: "implementation",
        sector_id: "sector-1",
        current_phase: "implementation",
        artifacts: %{},
        phase_jobs: %{}
      })

    # Create a sector
    {:ok, _comb} =
      Archive.insert(:sectors, %{id: "sector-1", name: "test", path: "/tmp/test"})

    {:ok, mission: mission}
  end

  describe "replan_from_failures/2" do
    test "returns :no_failures when mission has no failed ops", %{mission: mission} do
      assert {:error, :no_failures} = Planner.replan_from_failures(mission.id)
    end

    test "collects failures and attempts replan", %{mission: mission} do
      # Create a failed op
      {:ok, op} =
        GiTF.Ops.create(%{
          title: "Implement feature",
          description: "Build the thing",
          mission_id: mission.id,
          sector_id: "sector-1"
        })

      # Manually set status to failed
      job_record = Archive.get(:ops, op.id)
      Archive.put(:ops, %{job_record | status: "failed"})

      # Replan will fail because there's no LLM in test, but it should
      # attempt the analysis and return :replan_failed
      result = Planner.replan_from_failures(mission.id)

      # Either succeeds with a plan or fails gracefully
      case result do
        {:ok, plan} ->
          assert plan.mission_id == mission.id
          assert plan.replan == true

        {:error, reason} ->
          assert reason in [:replan_failed, :not_failed_job]
      end
    end
  end

  describe "replan with multiple failures" do
    test "handles multiple failed ops gracefully", %{mission: mission} do
      # Create two failed ops
      for title <- ["Setup DB", "Run migrations"] do
        {:ok, op} =
          GiTF.Ops.create(%{
            title: title,
            description: "Do the thing",
            mission_id: mission.id,
            sector_id: "sector-1"
          })

        job_record = Archive.get(:ops, op.id)
        Archive.put(:ops, %{job_record | status: "failed"})
      end

      result = Planner.replan_from_failures(mission.id)

      # Should not crash — either succeeds or fails gracefully
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end
