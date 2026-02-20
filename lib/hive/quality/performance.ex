defmodule Hive.Quality.Performance do
  @moduledoc """
  Performance benchmarking for bee worktrees.
  """

  @doc """
  Run performance benchmarks on a cell.
  Returns {:ok, results} with performance score and metrics.
  """
  def benchmark(cell_path, comb) do
    benchmark_command = Map.get(comb, :benchmark_command)
    
    if benchmark_command do
      run_benchmark(cell_path, benchmark_command)
    else
      {:ok, %{
        metrics: [],
        score: 100,
        tool: "none",
        available: false
      }}
    end
  end

  @doc """
  Compare benchmark results against baseline.
  Returns {:ok, comparison} with regression detection.
  """
  def compare_baseline(current, baseline) when is_map(baseline) do
    regressions = detect_regressions(current.metrics, baseline.metrics)
    
    score = calculate_performance_score(regressions)
    
    {:ok, %{
      regressions: regressions,
      score: score,
      baseline_score: baseline.score
    }}
  end
  
  def compare_baseline(current, nil), do: {:ok, %{regressions: [], score: current.score}}

  defp run_benchmark(path, command) do
    start_time = System.monotonic_time(:millisecond)
    
    case System.cmd("sh", ["-c", command], cd: path, stderr_to_stdout: true) do
      {output, 0} ->
        end_time = System.monotonic_time(:millisecond)
        duration = end_time - start_time
        
        metrics = parse_benchmark_output(output, duration)
        
        {:ok, %{
          metrics: metrics,
          score: 100,  # No baseline = perfect score
          tool: "custom",
          available: true,
          output: output
        }}
      
      {output, _exit_code} ->
        {:error, {:benchmark_failed, output}}
    end
  rescue
    e -> {:error, {:benchmark_error, Exception.message(e)}}
  end

  defp parse_benchmark_output(output, duration) do
    metrics = [
      %{
        name: "execution_time",
        value: duration,
        unit: "ms"
      }
    ]
    
    # Try to extract common benchmark formats
    additional = []
    
    # Look for "X ops/sec" pattern
    additional = if Regex.match?(~r/(\d+\.?\d*)\s*ops?\/sec/i, output) do
      case Regex.run(~r/(\d+\.?\d*)\s*ops?\/sec/i, output) do
        [_, ops] ->
          [%{name: "throughput", value: String.to_float(ops), unit: "ops/sec"} | additional]
        _ ->
          additional
      end
    else
      additional
    end
    
    # Look for "X ms" or "X milliseconds" pattern
    additional = if Regex.match?(~r/(\d+\.?\d*)\s*m?s(?:ec)?/i, output) do
      case Regex.run(~r/(\d+\.?\d*)\s*m?s(?:ec)?/i, output) do
        [_, ms] ->
          [%{name: "latency", value: String.to_float(ms), unit: "ms"} | additional]
        _ ->
          additional
      end
    else
      additional
    end
    
    # Look for memory usage
    additional = if Regex.match?(~r/(\d+\.?\d*)\s*MB/i, output) do
      case Regex.run(~r/(\d+\.?\d*)\s*MB/i, output) do
        [_, mb] ->
          [%{name: "memory", value: String.to_float(mb), unit: "MB"} | additional]
        _ ->
          additional
      end
    else
      additional
    end
    
    metrics ++ additional
  end

  defp detect_regressions(current_metrics, baseline_metrics) do
    Enum.flat_map(current_metrics, fn current ->
      case Enum.find(baseline_metrics, &(&1.name == current.name)) do
        nil ->
          []
        
        baseline ->
          regression = calculate_regression(current, baseline)
          
          if regression.percent > 10.0 do  # >10% slower is a regression
            [regression]
          else
            []
          end
      end
    end)
  end

  defp calculate_regression(current, baseline) do
    # For time/latency metrics, higher is worse
    # For throughput/ops, lower is worse
    is_inverse = current.name in ["throughput", "ops"]
    
    change = if is_inverse do
      (baseline.value - current.value) / baseline.value * 100
    else
      (current.value - baseline.value) / baseline.value * 100
    end
    
    %{
      metric: current.name,
      baseline: baseline.value,
      current: current.value,
      percent: Float.round(change, 2),
      unit: current.unit,
      severity: regression_severity(change)
    }
  end

  defp regression_severity(percent) when percent > 50, do: 3  # Critical
  defp regression_severity(percent) when percent > 25, do: 2  # Warning
  defp regression_severity(_), do: 1  # Info

  defp calculate_performance_score(regressions) do
    penalty = Enum.reduce(regressions, 0, fn reg, acc ->
      case reg.severity do
        3 -> acc + 30  # Critical regression: -30 points
        2 -> acc + 15  # Warning regression: -15 points
        _ -> acc + 5   # Minor regression: -5 points
      end
    end)
    
    max(0, 100 - penalty)
  end
end
