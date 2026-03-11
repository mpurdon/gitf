defmodule GiTF.ClearanceTest do
  use ExUnit.Case, async: true

  alias GiTF.Clearance

  describe "verification_level/1" do
    test "returns :standard for ops with no trust data" do
      op = %{assigned_model: "sonnet", op_type: :implementation}
      assert Clearance.verification_level(op) == :standard
    end

    test "returns :standard for nil model" do
      op = %{assigned_model: nil, op_type: nil}
      assert Clearance.verification_level(op) == :standard
    end
  end

  describe "adjusted_thresholds/2" do
    setup do
      base = %{security: 70, performance: 60, composite: 65}
      {:ok, base: base}
    end

    test "strict raises thresholds by 20%", %{base: base} do
      result = Clearance.adjusted_thresholds(base, :strict)
      assert result.security == 84.0
      assert result.performance == 72.0
      assert result.composite == 78.0
    end

    test "standard returns base unchanged", %{base: base} do
      assert Clearance.adjusted_thresholds(base, :standard) == base
    end

    test "relaxed lowers thresholds by 20%", %{base: base} do
      result = Clearance.adjusted_thresholds(base, :relaxed)
      assert result.security == 56.0
      assert result.performance == 48.0
      assert result.composite == 52.0
    end

    test "auto_approve returns all zeros" do
      result = Clearance.adjusted_thresholds(%{security: 70, performance: 60, composite: 65}, :auto_approve)
      assert result == %{security: 0, performance: 0, composite: 0}
    end

    test "preserves non-numeric values in thresholds" do
      base = %{security: 70, label: "test"}
      result = Clearance.adjusted_thresholds(base, :strict)
      assert result.label == "test"
      assert result.security == 84.0
    end
  end

  describe "should_auto_merge?/1" do
    test "returns false for standard clearance ops" do
      # No trust data → :standard → false
      op = %{assigned_model: "sonnet", op_type: :implementation, risk_level: :low}
      refute Clearance.should_auto_merge?(op)
    end

    test "returns false when risk_level is not :low" do
      op = %{assigned_model: "sonnet", op_type: :implementation, risk_level: :high}
      refute Clearance.should_auto_merge?(op)
    end

    test "returns false for nil model" do
      op = %{assigned_model: nil, op_type: nil, risk_level: :low}
      refute Clearance.should_auto_merge?(op)
    end
  end
end
