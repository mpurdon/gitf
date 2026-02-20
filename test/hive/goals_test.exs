defmodule Hive.GoalsTest do
  use ExUnit.Case, async: false

  alias Hive.Goals
  alias Hive.Store

  setup do
    store_dir = Path.join(System.tmp_dir!(), "hive-goals-test-#{:rand.uniform(100000)}")
    File.mkdir_p!(store_dir)
    start_supervised!({Store, data_dir: store_dir})
    
    on_exit(fn -> File.rm_rf!(store_dir) end)
    
    %{store_dir: store_dir}
  end

  describe "validate_quest_completion/1" do
    test "validates completed quest" do
      quest = %{
        id: "qst-test",
        description: "Test quest",
        status: "active",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:quests, quest)
      
      job = %{
        id: "job-test",
        quest_id: "qst-test",
        status: "completed",
        verification_status: "passed",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:jobs, job)
      
      result = Goals.validate_quest_completion("qst-test")
      
      assert result.goal_achieved == {:achieved, "All jobs completed"}
      assert result.simplicity_score > 0
      assert result.completeness.completed == 1
    end
  end

  describe "validate_job/1" do
    test "validates completed job" do
      quest = %{
        id: "qst-job",
        description: "Test",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:quests, quest)
      
      job = %{
        id: "job-valid",
        quest_id: "qst-job",
        title: "Test job",
        status: "completed",
        verification_status: "passed",
        files_changed: 2,
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:jobs, job)
      
      result = Goals.validate_job("job-valid")
      
      assert result.goal_met == true
      assert result.simplicity == 100
    end
  end
end
