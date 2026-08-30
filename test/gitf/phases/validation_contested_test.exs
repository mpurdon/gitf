defmodule GiTF.Phases.ValidationContestedTest do
  @moduledoc """
  msn-978954. Its parent (msn-398fa4) judged FR-5 UNMET with a specific
  reason. The resumed child's validator looked at byte-identical code,
  called FR-5 met — and wrote the very same concern into `gaps` as
  "minor, non-blocking". Nothing anywhere in the pipeline made it
  confront the earlier verdict, so the flip was free and the gap shipped.

  A verdict that moves while the code stands still is not a verdict. The
  ratchet (`record_accepted_requirements/1`) already makes agreement
  monotonic; this is its fail-closed twin, which makes disagreement
  sticky. Flipping is still allowed — it is merely no longer free: an
  argument must be attached, and a bare assertion is mechanically
  downgraded to unmet.
  """
  use GiTF.StoreCase

  alias GiTF.Archive
  alias GiTF.Major.PhasePrompts
  alias GiTF.Missions
  alias GiTF.Phases.Validation

  # Long enough to clear the floor, which is the only property the gate
  # can actually check.
  @rebuttal "client.ex now retries 5xx three times with backoff, which is what the earlier round found missing"

  defp mission!(artifacts, fields \\ %{}) do
    {:ok, m} =
      Archive.insert(
        :missions,
        Map.merge(
          %{
            name: "contested",
            goal: "x",
            status: "active",
            sector_id: "no-such-sector",
            current_phase: "validation",
            artifacts: artifacts,
            ops: []
          },
          fields
        )
      )

    m
  end

  defp stored(mission_id, key \\ "validation"), do: Missions.get_artifact(mission_id, key)

  defp entry(artifact, id) do
    Enum.find(artifact["requirements_met"], &(&1["req_id"] == id))
  end

  defp contested(mission_id), do: Archive.get(:missions, mission_id)[:contested_requirements]
  defp accepted(mission_id), do: Archive.get(:missions, mission_id)[:accepted_requirements]

  # The shape the incident had: FR-5 stands rejected, and this round says
  # met with whatever `flip` carries.
  defp flip_mission(flip) do
    mission!(
      %{
        "validation" => %{
          "overall_verdict" => "pass",
          "gaps" => ["minor: retries are still absent, non-blocking"],
          "requirements_met" =>
            [%{"req_id" => "FR-1", "met" => true}] ++
              [Map.merge(%{"req_id" => "FR-5", "met" => true}, flip)]
        }
      },
      %{contested_requirements: [%{"req_id" => "FR-5", "reason" => "no retry on 5xx responses"}]}
    )
  end

  describe "enforce_contested_rebuttals/1 — the flip must be argued" do
    test "a bare met:true on a contested requirement is downgraded and fails the round" do
      m = flip_mission(%{"evidence" => "looks implemented to me"})

      Validation.enforce_contested_rebuttals(m)

      artifact = stored(m.id)
      assert artifact["overall_verdict"] == "fail"
      assert entry(artifact, "FR-5")["met"] == false
      assert entry(artifact, "FR-5")["rebuttal_missing"] == true

      # The evidence the validator offered survives — a post-mortem needs
      # to read the case next to the verdict that rejected it.
      assert entry(artifact, "FR-5")["evidence"] == "looks implemented to me"

      # An uncontested requirement in the same artifact is untouched.
      assert entry(artifact, "FR-1")["met"] == true

      gap = Enum.find(artifact["gaps"], &String.contains?(&1, "FR-5 was previously judged UNMET"))
      assert gap
      assert gap =~ "no retry on 5xx responses"
      assert gap =~ "rebuttal"

      # The original gap list is preserved, not replaced.
      assert "minor: retries are still absent, non-blocking" in artifact["gaps"]
    end

    test "the ratchet never sees the downgraded flip" do
      m = flip_mission(%{"evidence" => "looks implemented to me"})

      m
      |> Validation.enforce_contested_rebuttals()
      |> Validation.record_accepted_requirements()

      # This is the whole point of running the gate BEFORE the ratchet:
      # the ratchet is monotonic, so an accepted FR-5 could never be
      # retracted by any later round.
      assert accepted(m.id) == ["FR-1"]
    end

    test "a rebuttal that clears the floor is honoured — the artifact is untouched" do
      m = flip_mission(%{"rebuttal" => @rebuttal})

      assert Validation.enforce_contested_rebuttals(m) == m

      artifact = stored(m.id)
      assert artifact["overall_verdict"] == "pass"
      assert entry(artifact, "FR-5")["met"] == true
      refute entry(artifact, "FR-5")["rebuttal_missing"]
    end

    test "an argued flip banks the requirement and settles the contest" do
      m = flip_mission(%{"rebuttal" => @rebuttal})

      m
      |> Validation.enforce_contested_rebuttals()
      |> Validation.record_accepted_requirements()
      |> Validation.record_contested_requirements()

      assert "FR-5" in accepted(m.id)
      assert contested(m.id) == []
    end

    test "a rebuttal too short to be an argument counts as none" do
      m = flip_mission(%{"rebuttal" => "fixed, see the diff"})

      Validation.enforce_contested_rebuttals(m)

      assert stored(m.id)["overall_verdict"] == "fail"
      assert entry(stored(m.id), "FR-5")["rebuttal_missing"] == true
    end

    test "whitespace does not pad a rebuttal to length" do
      m = flip_mission(%{"rebuttal" => "  fixed" <> String.duplicate(" ", 60)})

      Validation.enforce_contested_rebuttals(m)

      assert entry(stored(m.id), "FR-5")["rebuttal_missing"] == true
    end

    test "an already-approved artifact is left alone — the mission has moved on" do
      m =
        mission!(
          %{
            "validation" => %{
              "overall_verdict" => "pass",
              "requires_approval" => false,
              "requirements_met" => [%{"req_id" => "FR-5", "met" => true}]
            }
          },
          %{contested_requirements: [%{"req_id" => "FR-5", "reason" => "no retry on 5xx"}]}
        )

      assert Validation.enforce_contested_rebuttals(m) == m

      # Rewriting a verdict that has already been acted on would only
      # desynchronise the record from what actually happened.
      assert stored(m.id)["overall_verdict"] == "pass"
      assert entry(stored(m.id), "FR-5")["met"] == true
    end

    test "a second pass finds nothing — the rewrite clears its own trigger" do
      m = flip_mission(%{"evidence" => "looks implemented to me"})

      once = Validation.enforce_contested_rebuttals(m)
      assert Validation.enforce_contested_rebuttals(once) == once
    end

    test "a requirement already accepted is no longer contested, so a met:true stands" do
      m = flip_mission(%{"evidence" => "looks implemented to me"})
      Archive.update(:missions, m.id, &Map.put(&1, :accepted_requirements, ["FR-5"]))
      {:ok, m} = Missions.get(m.id)

      assert Validation.enforce_contested_rebuttals(m) == m
      assert stored(m.id)["overall_verdict"] == "pass"
    end

    test "a mission with nothing contested is a no-op" do
      m =
        mission!(%{
          "validation" => %{"requirements_met" => [%{"req_id" => "FR-5", "met" => true}]}
        })

      assert Validation.enforce_contested_rebuttals(m) == m
    end

    test "the verdict path runs the gate before it judges" do
      m = flip_mission(%{"evidence" => "looks implemented to me"})

      # `pass` would route to sync or approval; the downgraded artifact
      # sends the round back into the fix loop instead.
      assert Validation.verdict(m, nil) == :wait
      assert stored(m.id)["overall_verdict"] == "fail"
    end
  end

  describe "record_contested_requirements/1" do
    test "records every unmet requirement with the evidence as its reason" do
      m =
        mission!(%{
          "validation" => %{
            "requirements_met" => [
              %{"req_id" => "FR-1", "met" => true},
              %{"req_id" => "FR-5", "met" => false, "evidence" => "no retry on 5xx responses"},
              %{"req_id" => "FR-6", "met" => false}
            ]
          }
        })

      updated = Validation.record_contested_requirements(m)

      assert updated.contested_requirements == [
               %{"req_id" => "FR-5", "reason" => "no retry on 5xx responses"},
               %{"req_id" => "FR-6", "reason" => "previously judged unmet"}
             ]

      assert contested(m.id) == updated.contested_requirements
    end

    test "the latest round's articulation replaces the earlier one" do
      m =
        mission!(
          %{
            "validation" => %{
              "requirements_met" => [
                %{
                  "req_id" => "FR-5",
                  "met" => false,
                  "evidence" => "retries exist but not on 503"
                }
              ]
            }
          },
          %{contested_requirements: [%{"req_id" => "FR-5", "reason" => "no retry at all"}]}
        )

      updated = Validation.record_contested_requirements(m)

      assert updated.contested_requirements == [
               %{"req_id" => "FR-5", "reason" => "retries exist but not on 503"}
             ]
    end

    test "a downgraded entry contributes its id but not its reason" do
      # Its evidence argues the requirement was MET — it is exactly the
      # text the gate just rejected, and it must not become the reason
      # the next round is asked to answer.
      m =
        mission!(
          %{
            "validation" => %{
              "requirements_met" => [
                %{
                  "req_id" => "FR-5",
                  "met" => false,
                  "rebuttal_missing" => true,
                  "evidence" => "looks implemented to me"
                }
              ]
            }
          },
          %{
            contested_requirements: [
              %{"req_id" => "FR-5", "reason" => "no retry on 5xx responses"}
            ]
          }
        )

      updated = Validation.record_contested_requirements(m)

      assert updated.contested_requirements == [
               %{"req_id" => "FR-5", "reason" => "no retry on 5xx responses"}
             ]
    end

    test "an accepted requirement drops out of the contested set" do
      m =
        mission!(
          %{
            "validation" => %{
              "requirements_met" => [%{"req_id" => "FR-5", "met" => false, "evidence" => "gone"}]
            }
          },
          %{accepted_requirements: ["FR-5"]}
        )

      # Not "recorded then filtered" — never recorded at all, so the
      # register is not even written.
      assert Validation.record_contested_requirements(m) == m
      refute contested(m.id)
    end

    test "malformed entries are ignored rather than poisoning the register" do
      m =
        mission!(%{
          "validation" => %{
            "requirements_met" => [
              %{"req_id" => "FR-5", "met" => false},
              %{"met" => false},
              %{"req_id" => "", "met" => false},
              %{"req_id" => 7, "met" => false},
              "not a map"
            ]
          }
        })

      assert Validation.record_contested_requirements(m).contested_requirements == [
               %{"req_id" => "FR-5", "reason" => "previously judged unmet"}
             ]
    end

    test "an unchanged register is not rewritten" do
      m =
        mission!(
          %{"validation" => %{"requirements_met" => [%{"req_id" => "FR-5", "met" => false}]}},
          %{
            contested_requirements: [%{"req_id" => "FR-5", "reason" => "previously judged unmet"}]
          }
        )

      assert Validation.record_contested_requirements(m) == m
    end

    test "nothing unmet leaves an empty register untouched" do
      m =
        mission!(%{
          "validation" => %{"requirements_met" => [%{"req_id" => "FR-1", "met" => true}]}
        })

      assert Validation.record_contested_requirements(m) == m
      refute contested(m.id)
    end
  end

  describe "the contested set reaches the next round's prompt" do
    test "quotes the standing verdict and states the mechanical downgrade" do
      prompt =
        PhasePrompts.validation_prompt(%{goal: "x", id: "msn-1"}, %{}, %{}, "",
          contested_requirements: [
            %{"req_id" => "FR-5", "reason" => "no retry on 5xx responses"}
          ]
        )

      assert prompt =~ "PREVIOUSLY JUDGED UNMET"
      assert prompt =~ "FR-5: no retry on 5xx responses"
      assert prompt =~ "rebuttal"
      assert prompt =~ "least #{Validation.rebuttal_min_chars()} characters"
      assert prompt =~ "mechanically downgraded"

      # The exact evasion msn-978954's validator used.
      assert prompt =~ "gaps` as minor"
    end

    test "the rebuttal field lives in the Output Format example, not only the block" do
      # msn-ac0539 round 2: the validator read the contested block (its
      # evidence opened "re-verified with rebuttal"), then followed the
      # schema example — which had no such field — and folded the argument
      # into `evidence`. The gate downgraded every entry and a fix attempt
      # burned on prompt compliance. The example is what a model anchors on.
      prompt =
        PhasePrompts.validation_prompt(%{goal: "x", id: "msn-1"}, %{}, %{}, "",
          contested_requirements: [%{"req_id" => "FR-5", "reason" => "no retry on 5xx responses"}]
        )

      [_, output_format] = String.split(prompt, "## Output Format", parts: 2)
      [schema] = Regex.run(~r/```json\n(.*?)```/s, output_format, capture: :all_but_first)
      assert schema =~ ~s("rebuttal")
      assert prompt =~ "SEPARATE field from `evidence`"
    end

    test "an empty set adds nothing to the prompt" do
      prompt =
        PhasePrompts.validation_prompt(%{goal: "x", id: "msn-1"}, %{}, %{}, "",
          contested_requirements: []
        )

      refute prompt =~ "PREVIOUSLY JUDGED UNMET"
    end

    test "a register of nothing but junk renders no block" do
      prompt =
        PhasePrompts.validation_prompt(%{goal: "x", id: "msn-1"}, %{}, %{}, "",
          contested_requirements: ["junk", %{"reason" => "no id"}]
        )

      refute prompt =~ "PREVIOUSLY JUDGED UNMET"
    end
  end
end
