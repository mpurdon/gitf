defmodule Hive.Intelligence.RetryFeedbackTest do
  use ExUnit.Case, async: false

  alias Hive.Intelligence.{FailureAnalysis, Retry}
  alias Hive.Store

  setup do
    store_dir = Path.join(System.tmp_dir!(), "hive-retry-fb-test-#{:rand.uniform(100_000)}")
    File.mkdir_p!(store_dir)
    Hive.Test.StoreHelper.stop_store()
    start_supervised!({Store, data_dir: store_dir})

    on_exit(fn -> File.rm_rf!(store_dir) end)

    %{store_dir: store_dir}
  end

  describe "feedback-enriched classification" do
    test "vague error + specific feedback yields correct type" do
      job = insert_failed_job("job-fb-1", error_message: "something went wrong")

      # Without feedback → :unknown
      {:ok, analysis_no_fb} = FailureAnalysis.analyze_failure(job.id, nil)
      assert analysis_no_fb.failure_type == :unknown

      # With feedback mentioning "timeout" → :timeout
      {:ok, analysis_fb} = FailureAnalysis.analyze_failure(job.id, "the process hit a timeout")
      assert analysis_fb.failure_type == :timeout
      assert analysis_fb.feedback == "the process hit a timeout"
    end

    test "feedback mentioning test failure overrides vague error" do
      job = insert_failed_job("job-fb-2", error_message: "exit code 1")

      {:ok, analysis} = FailureAnalysis.analyze_failure(job.id, "test suite failed on 3 tests")
      assert analysis.failure_type == :test_failure
    end

    test "feedback mentioning compilation error" do
      job = insert_failed_job("job-fb-3", error_message: "unknown error")

      {:ok, analysis} = FailureAnalysis.analyze_failure(job.id, "compilation errors in module Foo")
      assert analysis.failure_type == :compilation_error
    end
  end

  describe "feedback stored in retry_metadata" do
    test "feedback is threaded to retry job metadata" do
      job = insert_failed_job("job-fb-4", error_message: "timeout occurred")

      {:ok, new_job} = Retry.retry_with_strategy(job.id, "bee was stuck in a loop")

      assert new_job.retry_of == job.id
      assert new_job.retry_metadata[:feedback] == "bee was stuck in a loop"
    end

    test "nil feedback is stored as nil in metadata" do
      job = insert_failed_job("job-fb-5", error_message: "timeout occurred")

      {:ok, new_job} = Retry.retry_with_strategy(job.id, nil)

      assert new_job.retry_of == job.id
      assert new_job.retry_metadata[:feedback] == nil
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp insert_failed_job(id, opts) do
    job = %{
      id: id,
      quest_id: "qst-fb",
      comb_id: "comb-fb",
      title: "Feedback test job",
      description: "Test",
      status: "failed",
      error_message: opts[:error_message] || "",
      verification_result: opts[:verification_result] || "",
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    Store.insert(:jobs, job)
    job
  end
end
