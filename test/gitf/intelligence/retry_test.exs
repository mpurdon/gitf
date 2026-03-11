defmodule GiTF.Intelligence.RetryTest do
  use ExUnit.Case, async: false

  alias GiTF.Intelligence.Retry
  alias GiTF.Archive

  setup do
    store_dir = Path.join(System.tmp_dir!(), "section-retry-test-#{:rand.uniform(100000)}")
    File.mkdir_p!(store_dir)
    GiTF.Test.StoreHelper.stop_store()
    start_supervised!({Archive, data_dir: store_dir})
    
    on_exit(fn -> File.rm_rf!(store_dir) end)
    
    %{store_dir: store_dir}
  end

  describe "recommend_strategy/1" do
    test "recommends simplify for timeout" do
      assert Retry.recommend_strategy(:timeout) == :simplify_scope
    end

    test "recommends different model for compilation error" do
      assert Retry.recommend_strategy(:compilation_error) == :different_model
    end

    test "recommends transfer for context overflow" do
      assert Retry.recommend_strategy(:context_overflow) == :create_handoff
    end
  end

  describe "retry_with_strategy/1" do
    test "creates retry op with strategy" do
      op = %{
        id: "op-retry",
        mission_id: "qst-123",
        sector_id: "sector-test",
        title: "Test op",
        description: "Test",
        status: "failed",
        error_message: "timeout",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Archive.insert(:ops, op)
      
      {:ok, new_job} = Retry.retry_with_strategy(op.id)
      
      assert new_job.retry_of == op.id
      assert new_job.status == "pending"
      assert is_atom(new_job.retry_strategy)
      
      # Original op should be marked as retried
      original = Archive.get(:ops, op.id)
      assert original.retried_as == new_job.id
    end
  end
end
