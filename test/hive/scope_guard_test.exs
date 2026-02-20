defmodule Hive.ScopeGuardTest do
  use ExUnit.Case, async: false

  alias Hive.ScopeGuard
  alias Hive.Store

  setup do
    store_dir = Path.join(System.tmp_dir!(), "hive-scope-test-#{:rand.uniform(100000)}")
    File.mkdir_p!(store_dir)
    start_supervised!({Store, data_dir: store_dir})
    
    on_exit(fn -> File.rm_rf!(store_dir) end)
    
    %{store_dir: store_dir}
  end

  describe "check_scope/1" do
    test "approves in-scope job" do
      quest = %{
        id: "qst-scope",
        description: "Add feature",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:quests, quest)
      
      job = %{
        id: "job-scope",
        quest_id: "qst-scope",
        title: "Implement feature",
        files_changed: 3,
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:jobs, job)
      
      result = ScopeGuard.check_scope("job-scope")
      
      assert result.in_scope == true
      assert result.recommendation == :approved
    end

    test "detects scope violations" do
      quest = %{
        id: "qst-creep",
        description: "Simple fix",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:quests, quest)
      
      job = %{
        id: "job-creep",
        quest_id: "qst-creep",
        title: "Refactor entire system",
        files_changed: 20,
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:jobs, job)
      
      result = ScopeGuard.check_scope("job-creep")
      
      assert result.in_scope == false
      assert length(result.warnings) > 0
    end
  end
end
