defmodule GiTF.Phases.ValidationRatchetTest do
  @moduledoc """
  A fix round costs a full validation pass, and the last two runs spent
  theirs re-proving requirements an earlier round had already accepted —
  reaching the fix cap with 15 of 16 requirements settled and one real
  gap outstanding. Nothing carried the "settled" verdict forward, so
  every round started from zero.

  The ratchet is deliberately one-way. A later round that simply did not
  look at a requirement must not un-accept it; only the build/typecheck
  and the exec-validation ground truth are re-proven every round, and
  those are pinned in the prompt separately.
  """
  use GiTF.StoreCase

  alias GiTF.Archive
  alias GiTF.Major.PhasePrompts
  alias GiTF.Phases.Validation

  defp mission!(artifacts) do
    {:ok, m} =
      Archive.insert(:missions, %{
        name: "ratchet",
        goal: "x",
        status: "active",
        sector_id: "no-such-sector",
        current_phase: "validation",
        artifacts: artifacts,
        ops: []
      })

    m
  end

  defp accepted(mission_id), do: Archive.get(:missions, mission_id)[:accepted_requirements]

  describe "record_accepted_requirements/1" do
    test "records only the requirements a validator marked met" do
      m =
        mission!(%{
          "validation" => %{
            "overall_verdict" => "fail",
            "requirements_met" => [
              %{"req_id" => "FR-1", "met" => true},
              %{"req_id" => "FR-2", "met" => false},
              %{"req_id" => "FR-3", "met" => true}
            ]
          }
        })

      updated = Validation.record_accepted_requirements(m)

      assert Enum.sort(updated.accepted_requirements) == ["FR-1", "FR-3"]
      assert Enum.sort(accepted(m.id)) == ["FR-1", "FR-3"]
    end

    test "accumulates across rounds and never un-accepts" do
      m = mission!(%{})
      Archive.update(:missions, m.id, &Map.put(&1, :accepted_requirements, ["FR-1", "FR-2"]))

      # Round two looked at FR-3 only and said nothing about FR-1/FR-2.
      {:ok, m} = GiTF.Missions.get(m.id)

      GiTF.Missions.store_artifact(m.id, "validation", %{
        "overall_verdict" => "fail",
        "requirements_met" => [%{"req_id" => "FR-3", "met" => true}]
      })

      {:ok, m} = GiTF.Missions.get(m.id)
      Validation.record_accepted_requirements(m)

      assert Enum.sort(accepted(m.id)) == ["FR-1", "FR-2", "FR-3"]
    end

    test "a tournament's losing variants still contribute what they proved" do
      m =
        mission!(%{
          "validation_v1" => %{"requirements_met" => [%{"req_id" => "FR-1", "met" => true}]},
          "validation_v2" => %{"requirements_met" => [%{"req_id" => "FR-2", "met" => true}]}
        })

      Validation.record_accepted_requirements(m)

      assert Enum.sort(accepted(m.id)) == ["FR-1", "FR-2"]
    end

    test "malformed entries are ignored rather than poisoning the set" do
      m =
        mission!(%{
          "validation" => %{
            "requirements_met" => [
              %{"req_id" => "FR-1", "met" => true},
              %{"met" => true},
              %{"req_id" => "", "met" => true},
              %{"req_id" => 7, "met" => true},
              "not a map"
            ]
          }
        })

      Validation.record_accepted_requirements(m)

      assert accepted(m.id) == ["FR-1"]
    end

    test "nothing accepted leaves the record untouched" do
      m = mission!(%{"validation" => %{"requirements_met" => []}})

      assert Validation.record_accepted_requirements(m) == m
      refute accepted(m.id)
    end

    test "the verdict path records the ratchet as a side effect" do
      m =
        mission!(%{
          "validation" => %{
            "overall_verdict" => "fail",
            "gaps" => ["FR-4 missing"],
            "requirements_met" => [%{"req_id" => "FR-1", "met" => true}]
          }
        })

      assert Validation.verdict(m, nil) == :wait
      assert accepted(m.id) == ["FR-1"]
    end
  end

  describe "the accepted set reaches the next round's prompt" do
    test "pins them as settled and names what is never settled" do
      prompt =
        PhasePrompts.validation_prompt(%{goal: "x", id: "msn-1"}, %{}, %{}, "",
          accepted_requirements: ["FR-1", "FR-2", "FR-3"]
        )

      assert prompt =~ "ALREADY ACCEPTED"
      assert prompt =~ "do not re-litigate"
      assert prompt =~ "FR-1, FR-2, FR-3"

      # The two things a ratchet must never freeze.
      assert prompt =~ "build/typecheck"
      assert prompt =~ "execution validation above is ground truth"
    end

    test "an empty set adds nothing to the prompt" do
      prompt =
        PhasePrompts.validation_prompt(%{goal: "x", id: "msn-1"}, %{}, %{}, "",
          accepted_requirements: []
        )

      refute prompt =~ "ALREADY ACCEPTED"
    end
  end

  describe "missing ground truth is stated, not implied" do
    test "an infra note says absence is not evidence of passing" do
      prompt =
        PhasePrompts.validation_prompt(%{goal: "x", id: "msn-1"}, %{}, %{}, "",
          infra_notes: ["Ground truth was UNAVAILABLE this round: the runner crashed."]
        )

      assert prompt =~ "GROUND TRUTH UNAVAILABLE"
      assert prompt =~ "NOT evidence that the build passes"
    end

    test "no note adds nothing" do
      prompt = PhasePrompts.validation_prompt(%{goal: "x", id: "msn-1"}, %{}, %{}, "")
      refute prompt =~ "GROUND TRUTH UNAVAILABLE"
    end
  end
end
