defmodule GiTF.Intel.FailureAnalysisTest do
  use ExUnit.Case, async: false

  alias GiTF.Intel.FailureAnalysis
  alias GiTF.Archive

  setup do
    store_dir = Path.join(System.tmp_dir!(), "section-intel-test-#{:rand.uniform(100_000)}")
    File.mkdir_p!(store_dir)
    GiTF.Test.StoreHelper.stop_store()
    start_supervised!({Archive, data_dir: store_dir})

    on_exit(fn -> File.rm_rf!(store_dir) end)

    %{store_dir: store_dir}
  end

  describe "analyze_failure/1" do
    test "analyzes a failed op" do
      op = %{
        id: "op-failed",
        sector_id: "sector-test",
        status: "failed",
        error_message: "compilation error: undefined function",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      Archive.insert(:ops, op)

      {:ok, analysis} = FailureAnalysis.analyze_failure(op.id)

      assert analysis.op_id == op.id
      assert analysis.failure_type == :compilation_error
      assert is_binary(analysis.root_cause)
      assert is_list(analysis.suggestions)
      assert length(analysis.suggestions) > 0
    end

    test "classifies timeout failures" do
      op = %{
        id: "op-timeout",
        sector_id: "sector-test",
        status: "failed",
        error_message: "Job timeout after 30 minutes",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      Archive.insert(:ops, op)

      {:ok, analysis} = FailureAnalysis.analyze_failure(op.id)

      assert analysis.failure_type == :timeout
    end

    test "returns error for non-failed op" do
      op = %{
        id: "op-success",
        status: "done",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      Archive.insert(:ops, op)

      assert {:error, :not_failed_job} = FailureAnalysis.analyze_failure(op.id)
    end
  end

  describe "get_failure_patterns/1" do
    test "returns empty patterns for sector with no failures" do
      patterns = FailureAnalysis.get_failure_patterns("nonexistent")

      assert patterns == []
    end

    test "groups failures by type" do
      sector_id = "sector-patterns"

      # Create multiple failed ops
      for i <- 1..3 do
        op = %{
          id: "op-#{i}",
          sector_id: sector_id,
          status: "failed",
          error_message: "timeout",
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }

        Archive.insert(:ops, op)
        FailureAnalysis.analyze_failure(op.id)
      end

      patterns = FailureAnalysis.get_failure_patterns(sector_id)

      assert length(patterns) > 0
      timeout_pattern = Enum.find(patterns, &(&1.type == :timeout))
      assert timeout_pattern
      assert timeout_pattern.count == 3
    end
  end

  describe "learn_from_failures/1" do
    test "creates learning from failure patterns" do
      sector_id = "sector-learn"

      op = %{
        id: "op-learn",
        sector_id: sector_id,
        status: "failed",
        error_message: "test failed",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      Archive.insert(:ops, op)
      FailureAnalysis.analyze_failure(op.id)

      {:ok, learning} = FailureAnalysis.learn_from_failures(sector_id)

      assert learning.sector_id == sector_id
      assert is_list(learning.patterns)
      assert learning.total_failures > 0
    end
  end
end
