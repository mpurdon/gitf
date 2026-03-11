defmodule GiTF.MinimalismTest do
  use ExUnit.Case, async: false

  alias GiTF.Minimalism
  alias GiTF.Archive

  setup do
    store_dir = Path.join(System.tmp_dir!(), "section-min-test-#{:rand.uniform(100000)}")
    File.mkdir_p!(store_dir)
    GiTF.Test.StoreHelper.stop_store()
    start_supervised!({Archive, data_dir: store_dir})
    
    on_exit(fn -> File.rm_rf!(store_dir) end)
    
    %{store_dir: store_dir}
  end

  describe "analyze_implementation/1" do
    test "rates simple implementation as excellent" do
      op = %{
        id: "op-simple",
        title: "Add function",
        files_changed: 1,
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Archive.insert(:ops, op)
      
      result = Minimalism.analyze_implementation("op-simple")
      
      assert result.overall_rating == :excellent
      assert result.complexity_score <= 30
    end

    test "detects over-engineering" do
      op = %{
        id: "op-complex",
        title: "Add factory pattern with builder",
        files_changed: 15,
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Archive.insert(:ops, op)
      
      result = Minimalism.analyze_implementation("op-complex")
      
      assert result.overall_rating == :needs_simplification
      assert length(result.violations) > 0
    end
  end

  describe "is_minimal?/1" do
    test "returns true for minimal implementation" do
      op = %{
        id: "op-min",
        title: "Simple fix",
        files_changed: 2,
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Archive.insert(:ops, op)
      
      assert Minimalism.is_minimal?("op-min") == true
    end
  end
end
