defmodule Hive.Intelligence.RetryTest do
  use ExUnit.Case, async: false

  alias Hive.Intelligence.Retry
  alias Hive.Store

  setup do
    store_dir = Path.join(System.tmp_dir!(), "hive-retry-test-#{:rand.uniform(100000)}")
    File.mkdir_p!(store_dir)
    start_supervised!({Store, data_dir: store_dir})
    
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

    test "recommends handoff for context overflow" do
      assert Retry.recommend_strategy(:context_overflow) == :create_handoff
    end
  end

  describe "retry_with_strategy/1" do
    test "creates retry job with strategy" do
      job = %{
        id: "job-retry",
        quest_id: "qst-123",
        comb_id: "comb-test",
        title: "Test job",
        description: "Test",
        status: "failed",
        error_message: "timeout",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:jobs, job)
      
      {:ok, new_job} = Retry.retry_with_strategy(job.id)
      
      assert new_job.retry_of == job.id
      assert new_job.status == "pending"
      assert is_atom(new_job.retry_strategy)
      
      # Original job should be marked as retried
      original = Store.get(:jobs, job.id)
      assert original.retried_as == new_job.id
    end
  end
end
