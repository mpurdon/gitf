defmodule GiTF.Quality do
  @moduledoc """
  Quality assurance system for code analysis and scoring.
  """

  alias GiTF.Archive
  alias GiTF.Quality.StaticAnalysis
  alias GiTF.Quality.Security
  alias GiTF.Quality.Performance

  @doc """
  Run static analysis on a op's worktree.
  Returns {:ok, report} with score and issues.
  """
  def analyze_static(op_id, shell_path, language) do
    {:ok, %{issues: issues, score: score, tool: tool} = result} =
      StaticAnalysis.analyze(shell_path, language)

    report = %{
      id: generate_id("qr"),
      op_id: op_id,
      analysis_type: "static",
      score: score,
      issues: issues,
      tool: tool,
      tool_available: Map.get(result, :available, true),
      recommendations: generate_recommendations(issues),
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    Archive.insert(:quality_reports, report)
    {:ok, report}
  rescue
    e ->
      {:error, {:analysis_crashed, Exception.message(e)}}
  end

  @doc """
  Run security scan on a op's worktree.
  Returns {:ok, report} with security score and findings.
  """
  def analyze_security(op_id, shell_path, language) do
    {:ok, %{findings: findings, score: score, tool: tool}} =
      Security.scan(shell_path, language)

    report = %{
      id: generate_id("qr"),
      op_id: op_id,
      analysis_type: "security",
      score: score,
      issues: findings,
      tool: tool,
      tool_available: true,
      recommendations: generate_security_recommendations(findings),
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    Archive.insert(:quality_reports, report)
    {:ok, report}
  rescue
    e ->
      {:error, {:scan_crashed, Exception.message(e)}}
  end

  @doc """
  Run performance benchmarks on a op's worktree.
  Returns {:ok, report} with performance score and metrics.
  """
  def analyze_performance(op_id, shell_path, sector) do
    case Performance.benchmark(shell_path, sector) do
      {:ok, %{metrics: metrics, score: score, tool: tool} = result} ->
        # Check for baseline and compare
        baseline = get_performance_baseline(sector.id)

        final_score =
          if baseline do
            case Performance.compare_baseline(result, baseline) do
              {:ok, comparison} -> comparison.score
              _ -> score
            end
          else
            score
          end

        report = %{
          id: generate_id("qr"),
          op_id: op_id,
          analysis_type: "performance",
          score: final_score,
          issues: metrics,
          tool: tool,
          tool_available: Map.get(result, :available, true),
          recommendations: [],
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }

        Archive.insert(:quality_reports, report)
        {:ok, report}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Set performance baseline for a sector.
  """
  def set_performance_baseline(sector_id, metrics) do
    baseline = %{
      id: generate_id("pb"),
      sector_id: sector_id,
      metrics: metrics,
      score: 100,
      created_at: DateTime.utc_now()
    }

    Archive.insert(:performance_baselines, baseline)
  end

  @doc """
  Get performance baseline for a sector.
  """
  def get_performance_baseline(sector_id) do
    Archive.all(:performance_baselines)
    |> Enum.filter(&(&1.sector_id == sector_id))
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
    |> List.first()
  end

  @doc """
  Get all quality reports for a op.
  """
  def get_reports(op_id) do
    Archive.all(:quality_reports)
    |> Enum.filter(&(&1.op_id == op_id))
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  @doc """
  Get the latest quality report for a op by type.
  """
  def get_latest_report(op_id, analysis_type) do
    get_reports(op_id)
    |> Enum.find(&(&1.analysis_type == analysis_type))
  end

  @doc """
  Calculate composite quality score for a op.
  Returns score 0-100 based on all available reports.
  """
  def calculate_composite_score(op_id) do
    reports = get_reports(op_id)

    if Enum.empty?(reports) do
      nil
    else
      # Weight: static 50%, security 30%, performance 20%
      static = Enum.find(reports, &(&1.analysis_type == "static"))
      security = Enum.find(reports, &(&1.analysis_type == "security"))
      performance = Enum.find(reports, &(&1.analysis_type == "performance"))

      cond do
        static && security && performance ->
          round(static.score * 0.5 + security.score * 0.3 + performance.score * 0.2)

        static && security ->
          round(static.score * 0.6 + security.score * 0.4)

        static && performance ->
          round(static.score * 0.7 + performance.score * 0.3)

        security && performance ->
          round(security.score * 0.6 + performance.score * 0.4)

        static ->
          static.score

        security ->
          security.score

        performance ->
          performance.score

        true ->
          nil
      end
    end
  end

  @doc """
  Check if a op meets quality thresholds.
  Returns {:ok, score} or {:error, reason}.
  """
  def check_quality_gate(op_id, threshold \\ 70) do
    case calculate_composite_score(op_id) do
      nil ->
        {:error, :no_reports}

      score when score >= threshold ->
        {:ok, score}

      score ->
        {:error, {:below_threshold, score, threshold}}
    end
  end

  @doc """
  Get configurable quality thresholds for a sector.
  Returns default thresholds if not configured.
  """
  def get_thresholds(sector_id) do
    case Archive.get(:sectors, sector_id) do
      nil ->
        default_thresholds()

      sector ->
        Map.get(sector, :quality_thresholds, default_thresholds())
    end
  end

  @doc """
  Set quality thresholds for a sector.
  """
  def set_thresholds(sector_id, thresholds) do
    case Archive.get(:sectors, sector_id) do
      nil ->
        {:error, :comb_not_found}

      sector ->
        updated = Map.put(sector, :quality_thresholds, thresholds)
        Archive.put(:sectors, updated)
        {:ok, updated}
    end
  end

  @doc """
  Get quality trends for a sector.
  Returns list of scores over time.
  """
  def get_quality_trends(sector_id, limit \\ 10) do
    # Get all ops for this sector
    ops = Archive.filter(:ops, &(&1.sector_id == sector_id and &1.status == "done"))

    # Calculate scores and sort by completion time
    ops
    |> Enum.map(fn op ->
      score = calculate_composite_score(op.id)

      %{
        op_id: op.id,
        score: score,
        completed_at: Map.get(op, :completed_at) || op.updated_at
      }
    end)
    |> Enum.reject(&is_nil(&1.score))
    |> Enum.sort_by(& &1.completed_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  @doc """
  Get quality statistics for a sector.
  """
  def get_quality_stats(sector_id) do
    trends = get_quality_trends(sector_id, 100)

    if Enum.empty?(trends) do
      %{
        average: nil,
        min: nil,
        max: nil,
        trend: :unknown,
        total_jobs: 0
      }
    else
      scores = Enum.map(trends, & &1.score)

      %{
        average: Float.round(Enum.sum(scores) / length(scores), 1),
        min: Enum.min(scores),
        max: Enum.max(scores),
        trend: calculate_trend(trends),
        total_jobs: length(trends)
      }
    end
  end

  defp default_thresholds do
    %{
      composite: 70,
      static: 70,
      security: 60,
      performance: 50
    }
  end

  defp calculate_trend(trends) when length(trends) < 3, do: :insufficient_data

  defp calculate_trend(trends) do
    # Compare recent vs older scores
    recent_scores = trends |> Enum.take(3) |> Enum.map(& &1.score)
    recent = Enum.sum(recent_scores) / 3

    older_scores = trends |> Enum.drop(3) |> Enum.take(3) |> Enum.map(& &1.score)
    older = Enum.sum(older_scores) / 3

    diff = recent - older

    cond do
      diff > 5 -> :improving
      diff < -5 -> :declining
      true -> :stable
    end
  end

  defp generate_recommendations(issues) do
    issues
    |> Enum.filter(&(&1.severity >= 2))
    |> Enum.take(5)
    |> Enum.map(&"Fix #{&1.category} in #{&1.file}:#{&1.line}")
  end

  defp generate_security_recommendations(findings) do
    findings
    |> Enum.filter(&(&1.severity >= 2))
    |> Enum.take(5)
    |> Enum.map(fn f ->
      case f.type do
        "secret" -> "Remove #{f.message} from #{f.file}:#{f.line}"
        "dependency" -> "Update vulnerable dependency: #{f.message}"
        "vulnerability" -> "Fix #{f.message} in #{f.file}:#{f.line}"
        _ -> f.message
      end
    end)
  end

  defp generate_id(prefix) do
    "#{prefix}-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end
end
