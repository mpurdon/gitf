defmodule Hive.QualityTest do
  use ExUnit.Case, async: false

  alias Hive.Quality
  alias Hive.Store

  setup do
    store_dir = Path.join(System.tmp_dir!(), "hive-quality-test-#{:rand.uniform(100000)}")
    File.mkdir_p!(store_dir)
    start_supervised!({Store, data_dir: store_dir})
    
    on_exit(fn -> File.rm_rf!(store_dir) end)
    
    %{store_dir: store_dir}
  end

  describe "analyze_static/3" do
    test "creates quality report" do
      job_id = "job-test"
      cell_path = "/tmp"
      
      {:ok, report} = Quality.analyze_static(job_id, cell_path, :unknown)
      
      assert report.job_id == job_id
      assert report.analysis_type == "static"
      assert report.score == 100
      assert is_list(report.issues)
    end

    test "stores report in database" do
      job_id = "job-test2"
      
      {:ok, _report} = Quality.analyze_static(job_id, "/tmp", :unknown)
      
      reports = Quality.get_reports(job_id)
      assert length(reports) == 1
      assert hd(reports).job_id == job_id
    end
  end

  describe "get_reports/1" do
    test "returns empty list for job with no reports" do
      reports = Quality.get_reports("nonexistent")
      assert reports == []
    end

    test "returns all reports for a job" do
      job_id = "job-multi"
      
      {:ok, _} = Quality.analyze_static(job_id, "/tmp", :unknown)
      {:ok, _} = Quality.analyze_static(job_id, "/tmp", :unknown)
      
      reports = Quality.get_reports(job_id)
      assert length(reports) == 2
    end
  end

  describe "analyze_security/3" do
    test "creates security report" do
      job_id = "job-sec-test"
      cell_path = "/tmp"
      
      {:ok, report} = Quality.analyze_security(job_id, cell_path, :unknown)
      
      assert report.job_id == job_id
      assert report.analysis_type == "security"
      assert is_integer(report.score)
      assert is_list(report.issues)
    end

    test "stores security report in database" do
      job_id = "job-sec-test2"
      
      {:ok, _report} = Quality.analyze_security(job_id, "/tmp", :unknown)
      
      reports = Quality.get_reports(job_id)
      assert length(reports) == 1
      assert hd(reports).analysis_type == "security"
    end
  end

  describe "analyze_performance/3" do
    test "creates performance report" do
      job_id = "job-perf-test"
      comb = %{id: "comb-test", path: "/tmp"}
      
      {:ok, report} = Quality.analyze_performance(job_id, "/tmp", comb)
      
      assert report.job_id == job_id
      assert report.analysis_type == "performance"
      assert is_integer(report.score)
    end

    test "stores performance report in database" do
      job_id = "job-perf-test2"
      comb = %{id: "comb-test", path: "/tmp"}
      
      {:ok, _report} = Quality.analyze_performance(job_id, "/tmp", comb)
      
      reports = Quality.get_reports(job_id)
      assert length(reports) == 1
      assert hd(reports).analysis_type == "performance"
    end
  end

  describe "performance baselines" do
    test "set and get baseline" do
      comb_id = "comb-baseline"
      metrics = [%{name: "test", value: 100, unit: "ms"}]
      
      {:ok, _} = Quality.set_performance_baseline(comb_id, metrics)
      
      baseline = Quality.get_performance_baseline(comb_id)
      assert baseline.comb_id == comb_id
      assert baseline.metrics == metrics
    end

    test "returns nil when no baseline exists" do
      baseline = Quality.get_performance_baseline("nonexistent")
      assert is_nil(baseline)
    end
  end

  describe "calculate_composite_score/1" do
    test "returns nil for job with no reports" do
      score = Quality.calculate_composite_score("nonexistent")
      assert is_nil(score)
    end

    test "returns static analysis score" do
      job_id = "job-score"
      
      {:ok, _} = Quality.analyze_static(job_id, "/tmp", :unknown)
      
      score = Quality.calculate_composite_score(job_id)
      assert score == 100
    end

    test "returns weighted composite with both static and security" do
      job_id = "job-composite"
      
      {:ok, _} = Quality.analyze_static(job_id, "/tmp", :unknown)
      {:ok, _} = Quality.analyze_security(job_id, "/tmp", :unknown)
      
      score = Quality.calculate_composite_score(job_id)
      # Should be weighted average: static * 0.6 + security * 0.4
      assert is_integer(score)
      assert score >= 0 and score <= 100
    end

    test "returns weighted composite with all three types" do
      job_id = "job-composite-all"
      comb = %{id: "comb-test", path: "/tmp"}
      
      {:ok, _} = Quality.analyze_static(job_id, "/tmp", :unknown)
      {:ok, _} = Quality.analyze_security(job_id, "/tmp", :unknown)
      {:ok, _} = Quality.analyze_performance(job_id, "/tmp", comb)
      
      score = Quality.calculate_composite_score(job_id)
      # Should be weighted: static * 0.5 + security * 0.3 + performance * 0.2
      assert is_integer(score)
      assert score >= 0 and score <= 100
    end
  end

  describe "check_quality_gate/2" do
    test "passes when score meets threshold" do
      job_id = "job-gate-pass"
      
      {:ok, _} = Quality.analyze_static(job_id, "/tmp", :unknown)
      
      assert {:ok, 100} = Quality.check_quality_gate(job_id, 70)
    end

    test "fails when no reports exist" do
      assert {:error, :no_reports} = Quality.check_quality_gate("nonexistent", 70)
    end
  end

  describe "threshold management" do
    test "returns default thresholds for unconfigured comb" do
      thresholds = Quality.get_thresholds("nonexistent")
      
      assert thresholds.composite == 70
      assert thresholds.static == 70
      assert thresholds.security == 60
      assert thresholds.performance == 50
    end

    test "set and get custom thresholds" do
      comb_id = "comb-thresh"
      comb = %{id: comb_id, path: "/tmp"}
      Store.insert(:combs, comb)
      
      custom = %{composite: 80, static: 75, security: 70, performance: 60}
      {:ok, _} = Quality.set_thresholds(comb_id, custom)
      
      thresholds = Quality.get_thresholds(comb_id)
      assert thresholds.composite == 80
      assert thresholds.static == 75
    end
  end

  describe "quality trends" do
    test "returns empty trends for comb with no jobs" do
      trends = Quality.get_quality_trends("nonexistent")
      assert trends == []
    end

    test "calculates quality statistics" do
      comb_id = "comb-stats"
      
      # Create some jobs with quality reports
      for i <- 1..3 do
        job = %{
          id: "job-#{i}",
          comb_id: comb_id,
          status: "done",
          updated_at: DateTime.utc_now()
        }
        Store.insert(:jobs, job)
        {:ok, _} = Quality.analyze_static(job.id, "/tmp", :unknown)
      end
      
      stats = Quality.get_quality_stats(comb_id)
      
      assert stats.total_jobs == 3
      assert stats.average == 100.0
      assert stats.min == 100
      assert stats.max == 100
    end
  end
end
