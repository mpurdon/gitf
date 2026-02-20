defmodule Hive.MinimalismTest do
  use ExUnit.Case, async: false

  alias Hive.Minimalism
  alias Hive.Store

  setup do
    store_dir = Path.join(System.tmp_dir!(), "hive-min-test-#{:rand.uniform(100000)}")
    File.mkdir_p!(store_dir)
    start_supervised!({Store, data_dir: store_dir})
    
    on_exit(fn -> File.rm_rf!(store_dir) end)
    
    %{store_dir: store_dir}
  end

  describe "analyze_implementation/1" do
    test "rates simple implementation as excellent" do
      job = %{
        id: "job-simple",
        title: "Add function",
        files_changed: 1,
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:jobs, job)
      
      result = Minimalism.analyze_implementation("job-simple")
      
      assert result.overall_rating == :excellent
      assert result.complexity_score <= 30
    end

    test "detects over-engineering" do
      job = %{
        id: "job-complex",
        title: "Add factory pattern with builder",
        files_changed: 15,
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:jobs, job)
      
      result = Minimalism.analyze_implementation("job-complex")
      
      assert result.overall_rating == :needs_simplification
      assert length(result.violations) > 0
    end
  end

  describe "is_minimal?/1" do
    test "returns true for minimal implementation" do
      job = %{
        id: "job-min",
        title: "Simple fix",
        files_changed: 2,
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:jobs, job)
      
      assert Minimalism.is_minimal?("job-min") == true
    end
  end
end
