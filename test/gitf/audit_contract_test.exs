defmodule GiTF.AuditContractTest do
  use ExUnit.Case, async: true

  alias GiTF.AuditContract

  describe "default_contract/0" do
    test "returns expected defaults" do
      contract = AuditContract.default_contract()
      assert :static in contract.required_checks
      assert :security in contract.required_checks
      assert contract.thresholds.composite == 70
      assert contract.thresholds.security == 60
      assert contract.thresholds.performance == 50
      assert contract.thresholds.static == 70
      assert contract.skip_checks == []
      assert contract.auto_approve_eligible == true
      assert contract.custom_validation_command == nil
    end
  end

  describe "evaluate/2" do
    test "passes when all required checks meet thresholds" do
      contract = %{
        required_checks: [:static, :security],
        skip_checks: [],
        thresholds: %{composite: 70, static: 70, security: 60}
      }

      result = %{
        static_score: 80,
        security_score: 75,
        quality_score: 85
      }

      assert :pass = AuditContract.evaluate(contract, result)
    end

    test "fails when a required check is below threshold" do
      contract = %{
        required_checks: [:static, :security],
        skip_checks: [],
        thresholds: %{composite: 70, static: 70, security: 60}
      }

      result = %{
        static_score: 80,
        security_score: 50,
        quality_score: 85
      }

      assert {:fail, reasons} = AuditContract.evaluate(contract, result)
      assert Enum.any?(reasons, &String.contains?(&1, "security"))
    end

    test "fails when a required check has nil score" do
      contract = %{
        required_checks: [:static, :security],
        skip_checks: [],
        thresholds: %{composite: 70, static: 70, security: 60}
      }

      result = %{
        static_score: 80,
        security_score: nil,
        quality_score: 85
      }

      assert {:fail, reasons} = AuditContract.evaluate(contract, result)
      assert Enum.any?(reasons, &String.contains?(&1, "security"))
    end

    test "skipped checks are not evaluated" do
      contract = %{
        required_checks: [:static, :security],
        skip_checks: [:security],
        thresholds: %{composite: 70, static: 70, security: 60}
      }

      result = %{
        static_score: 80,
        security_score: nil,
        quality_score: 85
      }

      assert :pass = AuditContract.evaluate(contract, result)
    end

    test "composite threshold is always checked if present" do
      contract = %{
        required_checks: [:static],
        skip_checks: [],
        thresholds: %{composite: 70, static: 70}
      }

      result = %{
        static_score: 80,
        quality_score: 50
      }

      assert {:fail, reasons} = AuditContract.evaluate(contract, result)
      assert Enum.any?(reasons, &String.contains?(&1, "composite"))
    end
  end

  describe "sync/2" do
    test "override thresholds take precedence" do
      base = %{
        required_checks: [:static],
        skip_checks: [],
        thresholds: %{composite: 70, security: 60}
      }

      override = %{
        required_checks: [:security],
        thresholds: %{security: 80}
      }

      merged = AuditContract.sync(base, override)
      assert :static in merged.required_checks
      assert :security in merged.required_checks
      assert merged.thresholds.security == 80
      assert merged.thresholds.composite == 70
    end

    test "union of required_checks and skip_checks" do
      base = %{required_checks: [:static], skip_checks: [:performance], thresholds: %{}}
      override = %{required_checks: [:security], skip_checks: [:static], thresholds: %{}}

      merged = AuditContract.sync(base, override)
      assert :static in merged.required_checks
      assert :security in merged.required_checks
      assert :performance in merged.skip_checks
      assert :static in merged.skip_checks
    end

    test "non-collection fields are overridden" do
      base = %{
        required_checks: [],
        skip_checks: [],
        thresholds: %{},
        auto_approve_eligible: true,
        custom_validation_command: nil
      }

      override = %{
        required_checks: [],
        skip_checks: [],
        thresholds: %{},
        auto_approve_eligible: false,
        custom_validation_command: "mix test"
      }

      merged = AuditContract.sync(base, override)
      assert merged.auto_approve_eligible == false
      assert merged.custom_validation_command == "mix test"
    end
  end

  describe "build_contract/1 risk adjustments" do
    test "high risk adds performance check and raises thresholds" do
      op = %{
        sector_id: "nonexistent",
        risk_level: :high,
        verification_contract: nil
      }

      contract = AuditContract.build_contract(op)
      assert :performance in contract.required_checks
      # Thresholds should be raised ~10%
      assert contract.thresholds.composite > 70
      assert contract.thresholds.security > 60
      assert contract.auto_approve_eligible == false
    end

    test "low risk uses default thresholds" do
      op = %{
        sector_id: "nonexistent",
        risk_level: :low,
        verification_contract: nil
      }

      contract = AuditContract.build_contract(op)
      assert contract.thresholds.composite == 70
      assert contract.thresholds.security == 60
      assert contract.auto_approve_eligible == true
    end

    test "op-level contract overrides are applied" do
      op = %{
        sector_id: "nonexistent",
        risk_level: :low,
        verification_contract: %{
          required_checks: [:performance],
          thresholds: %{composite: 90}
        }
      }

      contract = AuditContract.build_contract(op)
      assert :performance in contract.required_checks
      assert :static in contract.required_checks
      assert contract.thresholds.composite == 90
    end
  end
end
