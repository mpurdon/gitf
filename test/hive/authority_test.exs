defmodule Hive.AuthorityTest do
  use ExUnit.Case, async: true

  alias Hive.Authority

  describe "verification_level/1" do
    test "returns :standard for jobs with no reputation data" do
      job = %{assigned_model: "sonnet", job_type: :implementation}
      assert Authority.verification_level(job) == :standard
    end

    test "returns :standard for nil model" do
      job = %{assigned_model: nil, job_type: nil}
      assert Authority.verification_level(job) == :standard
    end
  end

  describe "adjusted_thresholds/2" do
    setup do
      base = %{security: 70, performance: 60, composite: 65}
      {:ok, base: base}
    end

    test "strict raises thresholds by 20%", %{base: base} do
      result = Authority.adjusted_thresholds(base, :strict)
      assert result.security == 84.0
      assert result.performance == 72.0
      assert result.composite == 78.0
    end

    test "standard returns base unchanged", %{base: base} do
      assert Authority.adjusted_thresholds(base, :standard) == base
    end

    test "relaxed lowers thresholds by 20%", %{base: base} do
      result = Authority.adjusted_thresholds(base, :relaxed)
      assert result.security == 56.0
      assert result.performance == 48.0
      assert result.composite == 52.0
    end

    test "auto_approve returns all zeros" do
      result = Authority.adjusted_thresholds(%{security: 70, performance: 60, composite: 65}, :auto_approve)
      assert result == %{security: 0, performance: 0, composite: 0}
    end

    test "preserves non-numeric values in thresholds" do
      base = %{security: 70, label: "test"}
      result = Authority.adjusted_thresholds(base, :strict)
      assert result.label == "test"
      assert result.security == 84.0
    end
  end

  describe "should_auto_merge?/1" do
    test "returns false for standard authority jobs" do
      # No reputation data → :standard → false
      job = %{assigned_model: "sonnet", job_type: :implementation, risk_level: :low}
      refute Authority.should_auto_merge?(job)
    end

    test "returns false when risk_level is not :low" do
      job = %{assigned_model: "sonnet", job_type: :implementation, risk_level: :high}
      refute Authority.should_auto_merge?(job)
    end

    test "returns false for nil model" do
      job = %{assigned_model: nil, job_type: nil, risk_level: :low}
      refute Authority.should_auto_merge?(job)
    end
  end
end
