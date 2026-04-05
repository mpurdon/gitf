defmodule GiTF.Quality.PerformanceTest do
  use ExUnit.Case, async: true

  alias GiTF.Quality.Performance

  describe "benchmark/2" do
    test "returns score and metrics when no benchmark command" do
      sector = %{id: "test", path: "/tmp"}

      {:ok, result} = Performance.benchmark("/tmp", sector)

      assert result.score == 100
      assert result.metrics == []
      assert result.tool == "none"
      assert result.available == false
    end

    test "runs benchmark command when configured" do
      sector = %{id: "test", path: "/tmp", benchmark_command: "echo 'test'"}

      {:ok, result} = Performance.benchmark("/tmp", sector)

      assert result.score == 100
      assert is_list(result.metrics)
      assert result.tool == "custom"
      assert result.available == true
    end

    test "extracts execution time metric" do
      sector = %{benchmark_command: "sleep 0.1"}

      {:ok, result} = Performance.benchmark("/tmp", sector)

      time_metric = Enum.find(result.metrics, &(&1.name == "execution_time"))
      assert time_metric
      # At least 100ms
      assert time_metric.value >= 100
      assert time_metric.unit == "ms"
    end
  end

  describe "compare_baseline/2" do
    test "returns no regressions when no baseline" do
      current = %{metrics: [], score: 100}

      {:ok, comparison} = Performance.compare_baseline(current, nil)

      assert comparison.regressions == []
      assert comparison.score == 100
    end

    test "detects performance regression" do
      baseline = %{
        metrics: [%{name: "execution_time", value: 100, unit: "ms"}],
        score: 100
      }

      current = %{
        metrics: [%{name: "execution_time", value: 200, unit: "ms"}],
        score: 100
      }

      {:ok, comparison} = Performance.compare_baseline(current, baseline)

      assert length(comparison.regressions) > 0
      regression = hd(comparison.regressions)
      assert regression.metric == "execution_time"
      # 100% slower
      assert regression.percent == 100.0
    end
  end
end
