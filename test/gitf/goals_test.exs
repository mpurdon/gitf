defmodule GiTF.GoalsTest do
  use ExUnit.Case, async: false

  alias GiTF.Goals
  alias GiTF.Archive

  setup do
    store_dir = Path.join(System.tmp_dir!(), "section-goals-test-#{:rand.uniform(100_000)}")
    File.mkdir_p!(store_dir)
    GiTF.Test.StoreHelper.stop_store()
    start_supervised!({Archive, data_dir: store_dir})

    on_exit(fn -> File.rm_rf!(store_dir) end)

    %{store_dir: store_dir}
  end

  describe "validate_quest_completion/1" do
    test "validates completed mission" do
      mission = %{
        id: "msn-test",
        description: "Test mission",
        status: "active",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      Archive.insert(:missions, mission)

      op = %{
        id: "op-test",
        mission_id: "msn-test",
        status: "completed",
        verification_status: "passed",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      Archive.insert(:ops, op)

      result = Goals.validate_quest_completion("msn-test")

      assert result.goal_achieved == {:achieved, "All ops completed"}
      assert result.simplicity_score > 0
      assert result.completeness.completed == 1
    end
  end

  describe "validate_job/1" do
    test "validates completed op" do
      mission = %{
        id: "msn-op",
        description: "Test",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      Archive.insert(:missions, mission)

      op = %{
        id: "op-valid",
        mission_id: "msn-op",
        title: "Test op",
        status: "completed",
        verification_status: "passed",
        files_changed: 2,
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      Archive.insert(:ops, op)

      result = Goals.validate_job("op-valid")

      assert result.goal_met == true
      assert result.simplicity == 100
    end
  end
end
