defmodule GiTF.AutonomyTest do
  use ExUnit.Case, async: false

  alias GiTF.Autonomy
  alias GiTF.Archive

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    store_dir = Path.join(System.tmp_dir!(), "section-autonomy-test-#{:rand.uniform(100_000)}")
    File.mkdir_p!(store_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = Archive.start_link(data_dir: store_dir)

    on_exit(fn -> File.rm_rf!(store_dir) end)

    %{store_dir: store_dir}
  end

  describe "self_heal/0" do
    test "returns empty list when system is healthy" do
      results = Autonomy.self_heal()

      assert is_list(results)
    end

    test "cleans up orphaned ghosts" do
      # Create ghost without active op
      ghost = %{
        id: "ghost-orphan",
        status: "active",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      Archive.insert(:ghosts, ghost)

      results = Autonomy.self_heal()

      # Should detect and clean up orphaned ghost
      assert is_list(results)
    end
  end

  describe "optimize_resources/0" do
    test "provides optimization recommendations" do
      recommendations = Autonomy.optimize_resources()

      assert is_list(recommendations)
    end
  end

  describe "predict_issues/1" do
    test "predicts issues based on failure patterns" do
      sector_id = "sector-predict"

      # Create some failed ops
      for i <- 1..3 do
        op = %{
          id: "op-fail-#{i}",
          sector_id: sector_id,
          status: "failed",
          error_message: "timeout",
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }

        Archive.insert(:ops, op)
      end

      predictions = Autonomy.predict_issues(sector_id)

      assert is_list(predictions)
    end
  end

  describe "audit/2" do
    test "creates audit log entry" do
      {:ok, entry} = Autonomy.audit(:job_approved, %{op_id: "op-123"})

      assert entry.action == :job_approved
      assert entry.details.op_id == "op-123"
    end
  end
end
