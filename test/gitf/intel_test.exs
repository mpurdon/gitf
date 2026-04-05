defmodule GiTF.IntelTest do
  use ExUnit.Case, async: false

  alias GiTF.Intel
  alias GiTF.Archive

  setup do
    store_dir = Path.join(System.tmp_dir!(), "section-intel-test-#{:rand.uniform(100_000)}")
    File.mkdir_p!(store_dir)
    GiTF.Test.StoreHelper.stop_store()
    start_supervised!({Archive, data_dir: store_dir})

    on_exit(fn -> File.rm_rf!(store_dir) end)

    %{store_dir: store_dir}
  end

  describe "analyze_and_suggest/1" do
    test "provides analysis and suggestions" do
      op = %{
        id: "op-analyze",
        sector_id: "sector-test",
        status: "failed",
        error_message: "test failed",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      Archive.insert(:ops, op)

      {:ok, result} = Intel.analyze_and_suggest(op.id)

      assert result.analysis
      assert result.recommended_strategy
      assert is_list(result.suggestions)
    end
  end

  describe "get_insights/1" do
    test "provides intel insights for sector" do
      sector_id = "sector-insights"

      # Create some ops
      for i <- 1..5 do
        status = if rem(i, 2) == 0, do: "done", else: "failed"

        op = %{
          id: "op-#{i}",
          sector_id: sector_id,
          status: status,
          error_message: if(status == "failed", do: "timeout", else: ""),
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }

        Archive.insert(:ops, op)
      end

      insights = Intel.get_insights(sector_id)

      assert insights.sector_id == sector_id
      assert insights.total_jobs == 5
      assert insights.failed_jobs == 3
      assert insights.success_rate == 40.0
    end
  end
end
