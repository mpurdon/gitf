defmodule GiTF.Dashboard.PhaseDecisionsTest do
  @moduledoc """
  The decision strip answers "what was decided in this phase?" from
  LLM-emitted artifacts, so every field is optional and every shape is
  hostile. These pin the extraction, not the markup.
  """

  use ExUnit.Case, async: true

  alias GiTF.Dashboard.MissionDetailLive, as: Live

  test "triage: complexity, the skips, and reproducibility" do
    artifact = %{
      "complexity" => "simple",
      "skip_flags" => %{"skip_research" => true, "skip_design" => false},
      "bug_reproducible" => false
    }

    assert [
             {"complexity", "simple", "green"},
             {"skipped", "research", "grey"},
             {"bug reproducible", "false", "grey"}
           ] =
             Live.decisions("triage", artifact)
  end

  test "validation: verdict, met-count, gap count" do
    artifact = %{
      "overall_verdict" => "fail",
      "requirements_met" => [
        %{"req_id" => "FR-1", "met" => true},
        %{"req_id" => "FR-2", "met" => false}
      ],
      "gaps" => ["conflict markers"]
    }

    assert [
             {"verdict", "fail", "red"},
             {"requirements", "1/2 met", "grey"},
             {"gaps", "1", "yellow"}
           ] =
             Live.decisions("validation", artifact)
  end

  test "review: selection and approval" do
    assert [{"selected", "normal", "purple"}, {"approved", "true", "green"}] =
             Live.decisions("review", %{"selected_design" => "normal", "approved" => true})
  end

  test "scoring: one chip per dimension, toned by score" do
    artifact = %{
      "final_output" => %{"score" => 92},
      "trajectory" => %{"score" => 70},
      "safety" => %{"score" => 40}
    }

    assert [
             {"final output", "92", "green"},
             {"trajectory", "70", "yellow"},
             {"safety", "40", "red"}
           ] = Live.decisions("scoring", artifact)
  end

  test "simplify: a skip explains itself" do
    assert [{"skipped", "triage_complexity_low", "grey"}] =
             Live.decisions("simplify", %{
               "skipped" => true,
               "skipped_reason" => "triage_complexity_low"
             })
  end

  test "hostile or empty artifacts yield no chips, never a crash" do
    for phase <- ~w(triage review validation sync simplify scoring research unknown) do
      assert Live.decisions(phase, %{}) == []

      assert Live.decisions(phase, %{"skip_flags" => nil, "requirements_met" => "not a list"})
             |> is_list()

      assert Live.decisions(phase, nil) == []
    end
  end
end
