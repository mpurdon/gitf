defmodule Hive.AcceptanceTest do
  use ExUnit.Case, async: false

  alias Hive.Acceptance
  alias Hive.Store

  setup do
    store_dir = Path.join(System.tmp_dir!(), "hive-accept-test-#{:rand.uniform(100000)}")
    File.mkdir_p!(store_dir)
    start_supervised!({Store, data_dir: store_dir})
    
    on_exit(fn -> File.rm_rf!(store_dir) end)
    
    %{store_dir: store_dir}
  end

  describe "test_acceptance/1" do
    test "approves job meeting all criteria" do
      quest = %{
        id: "qst-accept",
        description: "Test",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:quests, quest)
      
      job = %{
        id: "job-accept",
        quest_id: "qst-accept",
        title: "Simple implementation",
        status: "completed",
        verification_status: "passed",
        quality_score: 85,
        files_changed: 2,
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:jobs, job)
      
      result = Acceptance.test_acceptance("job-accept")
      
      assert result.goal_met == true
      assert result.in_scope == true
      assert result.is_minimal == true
      assert result.quality_passed == true
      assert result.ready_to_merge == true
      assert Enum.empty?(result.blockers)
    end

    test "blocks job with violations" do
      quest = %{
        id: "qst-block",
        description: "Test",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:quests, quest)
      
      job = %{
        id: "job-block",
        quest_id: "qst-block",
        title: "Complex refactor",
        status: "in_progress",
        quality_score: 50,
        files_changed: 20,
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:jobs, job)
      
      result = Acceptance.test_acceptance("job-block")
      
      assert result.ready_to_merge == false
      assert length(result.blockers) > 0
    end
  end
end
