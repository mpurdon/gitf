defmodule GiTF.BarrierTest do
  use ExUnit.Case, async: false

  alias GiTF.Barrier
  alias GiTF.Archive

  setup do
    store_dir = Path.join(System.tmp_dir!(), "section-scope-test-#{:rand.uniform(100000)}")
    File.mkdir_p!(store_dir)
    GiTF.Test.StoreHelper.stop_store()
    start_supervised!({Archive, data_dir: store_dir})
    
    on_exit(fn -> File.rm_rf!(store_dir) end)
    
    %{store_dir: store_dir}
  end

  describe "check_scope/1" do
    test "approves in-scope op" do
      mission = %{
        id: "qst-scope",
        description: "Add feature",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Archive.insert(:missions, mission)
      
      op = %{
        id: "op-scope",
        mission_id: "qst-scope",
        title: "Implement feature",
        files_changed: 3,
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Archive.insert(:ops, op)
      
      result = Barrier.check_scope("op-scope")
      
      assert result.in_scope == true
      assert result.recommendation == :approved
    end

    test "detects scope violations" do
      mission = %{
        id: "qst-creep",
        description: "Simple fix",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Archive.insert(:missions, mission)
      
      op = %{
        id: "op-creep",
        mission_id: "qst-creep",
        title: "Refactor entire system",
        files_changed: 20,
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Archive.insert(:ops, op)
      
      result = Barrier.check_scope("op-creep")
      
      assert result.in_scope == false
      assert length(result.warnings) > 0
    end
  end
end
