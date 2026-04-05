defmodule GiTF.QualityTest do
  use ExUnit.Case, async: false

  alias GiTF.Quality
  alias GiTF.Archive

  setup do
    store_dir = Path.join(System.tmp_dir!(), "section-quality-test-#{:rand.uniform(100_000)}")
    File.mkdir_p!(store_dir)
    GiTF.Test.StoreHelper.stop_store()
    start_supervised!({Archive, data_dir: store_dir})

    on_exit(fn -> File.rm_rf!(store_dir) end)

    %{store_dir: store_dir}
  end

  describe "analyze_static/3" do
    test "creates quality report" do
      op_id = "op-test"
      shell_path = "/tmp"

      {:ok, report} = Quality.analyze_static(op_id, shell_path, :unknown)

      assert report.op_id == op_id
      assert report.analysis_type == "static"
      assert report.score == 100
      assert is_list(report.issues)
    end

    test "stores report in database" do
      op_id = "op-test2"

      {:ok, _report} = Quality.analyze_static(op_id, "/tmp", :unknown)

      reports = Quality.get_reports(op_id)
      assert length(reports) == 1
      assert hd(reports).op_id == op_id
    end
  end

  describe "get_reports/1" do
    test "returns empty list for op with no reports" do
      reports = Quality.get_reports("nonexistent")
      assert reports == []
    end

    test "returns all reports for a op" do
      op_id = "op-multi"

      {:ok, _} = Quality.analyze_static(op_id, "/tmp", :unknown)
      {:ok, _} = Quality.analyze_static(op_id, "/tmp", :unknown)

      reports = Quality.get_reports(op_id)
      assert length(reports) == 2
    end
  end

  describe "analyze_security/3" do
    test "creates security report" do
      op_id = "op-sec-test"
      shell_path = "/tmp"

      {:ok, report} = Quality.analyze_security(op_id, shell_path, :unknown)

      assert report.op_id == op_id
      assert report.analysis_type == "security"
      assert is_integer(report.score)
      assert is_list(report.issues)
    end

    test "stores security report in database" do
      op_id = "op-sec-test2"

      {:ok, _report} = Quality.analyze_security(op_id, "/tmp", :unknown)

      reports = Quality.get_reports(op_id)
      assert length(reports) == 1
      assert hd(reports).analysis_type == "security"
    end
  end

  describe "analyze_performance/3" do
    test "creates performance report" do
      op_id = "op-perf-test"
      sector = %{id: "sector-test", path: "/tmp"}

      {:ok, report} = Quality.analyze_performance(op_id, "/tmp", sector)

      assert report.op_id == op_id
      assert report.analysis_type == "performance"
      assert is_integer(report.score)
    end

    test "stores performance report in database" do
      op_id = "op-perf-test2"
      sector = %{id: "sector-test", path: "/tmp"}

      {:ok, _report} = Quality.analyze_performance(op_id, "/tmp", sector)

      reports = Quality.get_reports(op_id)
      assert length(reports) == 1
      assert hd(reports).analysis_type == "performance"
    end
  end

  describe "performance baselines" do
    test "set and get baseline" do
      sector_id = "sector-baseline"
      metrics = [%{name: "test", value: 100, unit: "ms"}]

      {:ok, _} = Quality.set_performance_baseline(sector_id, metrics)

      baseline = Quality.get_performance_baseline(sector_id)
      assert baseline.sector_id == sector_id
      assert baseline.metrics == metrics
    end

    test "returns nil when no baseline exists" do
      baseline = Quality.get_performance_baseline("nonexistent")
      assert is_nil(baseline)
    end
  end

  describe "calculate_composite_score/1" do
    test "returns nil for op with no reports" do
      score = Quality.calculate_composite_score("nonexistent")
      assert is_nil(score)
    end

    test "returns static analysis score" do
      op_id = "op-score"

      {:ok, _} = Quality.analyze_static(op_id, "/tmp", :unknown)

      score = Quality.calculate_composite_score(op_id)
      assert score == 100
    end

    test "returns weighted composite with both static and security" do
      op_id = "op-composite"

      {:ok, _} = Quality.analyze_static(op_id, "/tmp", :unknown)
      {:ok, _} = Quality.analyze_security(op_id, "/tmp", :unknown)

      score = Quality.calculate_composite_score(op_id)
      # Should be weighted average: static * 0.6 + security * 0.4
      assert is_integer(score)
      assert score >= 0 and score <= 100
    end

    test "returns weighted composite with all three types" do
      op_id = "op-composite-all"
      sector = %{id: "sector-test", path: "/tmp"}

      {:ok, _} = Quality.analyze_static(op_id, "/tmp", :unknown)
      {:ok, _} = Quality.analyze_security(op_id, "/tmp", :unknown)
      {:ok, _} = Quality.analyze_performance(op_id, "/tmp", sector)

      score = Quality.calculate_composite_score(op_id)
      # Should be weighted: static * 0.5 + security * 0.3 + performance * 0.2
      assert is_integer(score)
      assert score >= 0 and score <= 100
    end
  end

  describe "check_quality_gate/2" do
    test "passes when score meets threshold" do
      op_id = "op-gate-pass"

      {:ok, _} = Quality.analyze_static(op_id, "/tmp", :unknown)

      assert {:ok, 100} = Quality.check_quality_gate(op_id, 70)
    end

    test "fails when no reports exist" do
      assert {:error, :no_reports} = Quality.check_quality_gate("nonexistent", 70)
    end
  end

  describe "threshold management" do
    test "returns default thresholds for unconfigured sector" do
      thresholds = Quality.get_thresholds("nonexistent")

      assert thresholds.composite == 70
      assert thresholds.static == 70
      assert thresholds.security == 60
      assert thresholds.performance == 50
    end

    test "set and get custom thresholds" do
      sector_id = "sector-thresh"
      sector = %{id: sector_id, path: "/tmp"}
      Archive.insert(:sectors, sector)

      custom = %{composite: 80, static: 75, security: 70, performance: 60}
      {:ok, _} = Quality.set_thresholds(sector_id, custom)

      thresholds = Quality.get_thresholds(sector_id)
      assert thresholds.composite == 80
      assert thresholds.static == 75
    end
  end

  describe "quality trends" do
    test "returns empty trends for sector with no ops" do
      trends = Quality.get_quality_trends("nonexistent")
      assert trends == []
    end

    test "calculates quality statistics" do
      sector_id = "sector-stats"

      # Create some ops with quality reports
      for i <- 1..3 do
        op = %{
          id: "op-#{i}",
          sector_id: sector_id,
          status: "done",
          updated_at: DateTime.utc_now()
        }

        Archive.insert(:ops, op)
        {:ok, _} = Quality.analyze_static(op.id, "/tmp", :unknown)
      end

      stats = Quality.get_quality_stats(sector_id)

      assert stats.total_jobs == 3
      assert stats.average == 100.0
      assert stats.min == 100
      assert stats.max == 100
    end
  end
end
