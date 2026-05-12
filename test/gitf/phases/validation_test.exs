defmodule GiTF.Phases.ValidationTest do
  use ExUnit.Case, async: true

  alias GiTF.Phases.Validation

  describe "verdict/1" do
    test ":pass when overall_verdict is 'pass'" do
      assert Validation.verdict(%{"overall_verdict" => "pass"}) == :pass
    end

    test ":pass when overall_verdict is 'passed'" do
      assert Validation.verdict(%{"overall_verdict" => "passed"}) == :pass
    end

    test ":fail when overall_verdict is 'fail'" do
      assert Validation.verdict(%{"overall_verdict" => "fail"}) == :fail
    end

    test ":fail when overall_verdict is 'failed'" do
      assert Validation.verdict(%{"overall_verdict" => "failed"}) == :fail
    end

    test ":inconclusive when overall_verdict is missing" do
      assert Validation.verdict(%{"requirements_met" => []}) == :inconclusive
    end

    test ":inconclusive on unrecognised verdict string" do
      assert Validation.verdict(%{"overall_verdict" => "unclear"}) == :inconclusive
    end

    test "falls back to top-level `verdict` field" do
      assert Validation.verdict(%{"verdict" => "pass"}) == :pass
    end

    test "falls back to nested `overall.verdict` path" do
      assert Validation.verdict(%{"overall" => %{"verdict" => "fail"}}) == :fail
    end

    test "accepts atom keys" do
      assert Validation.verdict(%{overall_verdict: "pass"}) == :pass
    end

    test ":inconclusive on non-map artifact" do
      assert Validation.verdict(nil) == :inconclusive
      assert Validation.verdict("pass") == :inconclusive
    end
  end
end
