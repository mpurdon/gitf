defmodule GiTF.EvalTest do
  use ExUnit.Case, async: false

  defmodule SyntheticScenario do
    @behaviour GiTF.Eval.Scenario

    def name, do: "synthetic"
    def description, do: "deterministic scenario for runner tests"

    def cases do
      [
        %{id: "c_pass", outcome: :pass},
        %{id: "c_fail", outcome: :fail},
        %{id: "c_skip", outcome: :skip},
        %{id: "c_raise", outcome: :raise}
      ]
    end

    def run(%{outcome: :pass}, _), do: {:pass, %{rank: 1}}
    def run(%{outcome: :fail}, _), do: {:fail, %{reason: "expected"}}
    def run(%{outcome: :skip}, _), do: {:skip, "by design"}
    def run(%{outcome: :raise}, _), do: raise("simulated crash")
  end

  describe "run/1" do
    test "executes every case and tallies pass/fail/skip" do
      report = GiTF.Eval.run(scenarios: [SyntheticScenario])

      assert [scenario] = report.scenarios
      assert scenario.name == "synthetic"
      assert scenario.counts == %{pass: 1, fail: 2, skip: 1}
      assert report.summary == %{pass: 1, fail: 2, skip: 1}
    end

    test "exception in run/2 is captured as a fail with reason" do
      report = GiTF.Eval.run(scenarios: [SyntheticScenario])
      raised = Enum.find(hd(report.scenarios).cases, &(&1.id == "c_raise"))
      assert raised.result == :fail
      assert raised.meta.reason =~ "raised"
    end

    test ":scenario filter narrows execution" do
      report = GiTF.Eval.run(scenarios: [SyntheticScenario], scenario: "synthetic")
      assert length(report.scenarios) == 1

      report = GiTF.Eval.run(scenarios: [SyntheticScenario], scenario: "no-such")
      assert report.scenarios == []
      assert report.summary == %{pass: 0, fail: 0, skip: 0}
    end

    test "elapsed_ms and started_at are populated" do
      report = GiTF.Eval.run(scenarios: [SyntheticScenario])
      assert is_integer(report.elapsed_ms) and report.elapsed_ms >= 0
      assert %DateTime{} = report.started_at
    end
  end

  describe "format_console/1" do
    test "renders header, per-case lines, and summary" do
      report = GiTF.Eval.run(scenarios: [SyntheticScenario])
      output = GiTF.Eval.format_console(report)

      assert output =~ "synthetic"
      assert output =~ "1P/2F/1S"
      assert output =~ "✓ c_pass"
      assert output =~ "✗ c_fail"
      assert output =~ "· c_skip"
      assert output =~ "Total: 4 cases"
      assert output =~ "pass-rate"
    end
  end

  describe "scenarios/0" do
    test "registers the skills_retrieval scenario" do
      assert GiTF.Eval.SkillsRetrieval in GiTF.Eval.scenarios()
    end
  end
end
