defmodule GiTF.AcceptanceTest do
  use ExUnit.Case, async: false

  alias GiTF.Acceptance
  alias GiTF.Archive

  setup do
    store_dir = Path.join(System.tmp_dir!(), "section-accept-test-#{:rand.uniform(100_000)}")
    File.mkdir_p!(store_dir)
    GiTF.Test.StoreHelper.stop_store()
    start_supervised!({Archive, data_dir: store_dir})

    on_exit(fn -> File.rm_rf!(store_dir) end)

    %{store_dir: store_dir}
  end

  describe "test_acceptance/1" do
    test "approves op meeting all criteria" do
      mission = %{
        id: "msn-accept",
        description: "Test",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      Archive.insert(:missions, mission)

      op = %{
        id: "op-accept",
        mission_id: "msn-accept",
        title: "Simple implementation",
        status: "completed",
        verification_status: "passed",
        quality_score: 85,
        files_changed: 2,
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      Archive.insert(:ops, op)

      result = Acceptance.test_acceptance("op-accept")

      assert result.goal_met == true
      assert result.in_scope == true
      assert result.is_minimal == true
      assert result.quality_passed == true
      assert result.ready_to_merge == true
      assert Enum.empty?(result.blockers)
    end

    test "blocks op with violations" do
      mission = %{
        id: "msn-block",
        description: "Test",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      Archive.insert(:missions, mission)

      op = %{
        id: "op-block",
        mission_id: "msn-block",
        title: "Complex refactor",
        status: "in_progress",
        quality_score: 50,
        files_changed: 20,
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      Archive.insert(:ops, op)

      result = Acceptance.test_acceptance("op-block")

      assert result.ready_to_merge == false
      assert length(result.blockers) > 0
    end
  end
end
