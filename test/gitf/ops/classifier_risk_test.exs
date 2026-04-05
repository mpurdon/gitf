defmodule GiTF.Ops.ClassifierRiskTest do
  use ExUnit.Case, async: true

  alias GiTF.Ops.Classifier

  describe "classify_risk/3" do
    test "returns :low for simple tasks" do
      assert Classifier.classify_risk("Fix typo in README") == :low
    end

    test "returns :medium for single high-risk keyword" do
      assert Classifier.classify_risk("Update database schema") == :medium
    end

    test "returns :high for two high-risk signals" do
      assert Classifier.classify_risk("Add auth migration") == :high
    end

    test "returns :critical for three or more high-risk signals" do
      assert Classifier.classify_risk("Deploy security fix with database migration") == :critical
    end

    test "considers description in risk assessment" do
      assert Classifier.classify_risk(
               "Update config",
               "Changes to authentication and credential handling"
             ) == :high
    end

    test "considers target files in risk assessment" do
      assert Classifier.classify_risk(
               "Update settings",
               nil,
               ["config/prod.exs", "lib/auth/session.ex"]
             ) == :high
    end

    test "Dockerfile is high-risk" do
      assert Classifier.classify_risk("Update build", nil, ["Dockerfile"]) == :medium
    end

    test ".env file is high-risk" do
      assert Classifier.classify_risk("Add variable", nil, [".env"]) == :medium
    end

    test "migration files are high-risk" do
      assert Classifier.classify_risk("Add column", nil, [
               "priv/repo/migrations/001_add_users.exs"
             ]) == :medium
    end

    test "no false positives on regular files" do
      assert Classifier.classify_risk("Update", nil, ["lib/app.ex", "test/app_test.exs"]) == :low
    end
  end

  describe "classify_and_recommend/2 includes risk_level" do
    test "includes risk_level in result" do
      result = Classifier.classify_and_recommend("Fix typo in docs")
      assert Map.has_key?(result, :risk_level)
      assert result.risk_level == :low
    end

    test "high-risk title yields elevated risk_level" do
      result = Classifier.classify_and_recommend("Add database migration for auth")
      assert result.risk_level in [:high, :critical]
    end
  end
end
