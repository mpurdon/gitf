defmodule GiTF.Approval.TriageTest do
  @moduledoc """
  The approval panel's job is a decision, and until now it handed the
  operator a verdict chip and two buttons. Everything that separates
  "ship it" from "read this first" was inside the validation artifact:
  whether gap #1 was a behavioral defect or a missing tooltip, whether a
  requirement flipped from a standing UNMET verdict, whether the software
  was ever actually run.

  `build/1` is a pure function of one mission map, so every case here is
  the artifact shape from a real run written out by hand.
  """
  use ExUnit.Case, async: true

  alias GiTF.Approval.Triage

  defp mission(artifacts, fields \\ %{}) do
    Map.merge(%{id: "msn-test", artifacts: artifacts}, fields)
  end

  defp validation(fields), do: mission(%{"validation" => fields})

  defp kinds(items), do: Enum.map(items, & &1.kind)

  # msn-ac0539: sixteen requirements, all met, five of them flipping a
  # verdict an earlier round had rejected and each carrying its argument.
  # One gap survived onto the pass verdict — the setting works but is not
  # surfaced in the UI.
  defp ac0539 do
    rebutted = ["FR-3", "FR-7", "FR-9", "FR-12", "FR-15"]

    entries =
      for n <- 1..16 do
        id = "FR-#{n}"
        entry = %{"req_id" => id, "met" => true, "evidence" => "covered by #{id} test"}

        if id in rebutted,
          do:
            Map.put(
              entry,
              "rebuttal",
              "the retry path now lives in client.ex:44, " <>
                "which is what the earlier round found missing"
            ),
          else: entry
      end

    mission(%{
      "validation" => %{
        "overall_verdict" => "pass",
        "requires_approval" => true,
        "requirements_met" => entries,
        "gaps" => ["the new timeout setting is not surfaced anywhere in the UI"]
      },
      "exec_validation" => %{"status" => "pass"}
    })
  end

  describe "the msn-ac0539 shape — a clean pass with one visibility gap" do
    test "0 fails, 1 concern, 16 ok" do
      triage = Triage.build(ac0539())

      assert triage.fails == []
      assert length(triage.concerns) == 1
      assert length(triage.oks) == 16
    end

    test "the gap is the only concern and it is a gap, not a verdict" do
      [concern] = Triage.build(ac0539()).concerns

      assert concern.status == :concerns
      assert concern.kind == :gap
      assert concern.title =~ "not surfaced anywhere in the UI"
    end

    test "the five rebutted requirements are marked as overturning a prior verdict" do
      oks = Triage.build(ac0539()).oks

      rebutted = Enum.filter(oks, &(&1.kind == :contested_rebutted))

      assert length(rebutted) == 5
      assert Enum.all?(rebutted, &(&1.status == :ok))
      assert Enum.all?(rebutted, &(&1.rebuttal =~ "client.ex:44"))
      assert Enum.all?(rebutted, &(&1.title =~ "overturns an earlier UNMET verdict"))
    end

    test "the plain eleven carry no rebuttal and say only that they are met" do
      plain = Triage.build(ac0539()).oks |> Enum.filter(&(&1.kind == :requirement))

      assert length(plain) == 11
      assert Enum.all?(plain, &(&1.rebuttal == nil))
      assert Enum.all?(plain, &(&1.title =~ "met"))
    end

    test "the tally reads the way the operator asked for it" do
      assert Triage.tally(Triage.build(ac0539())) == "0 fails · 1 concern · 16 ok"
    end
  end

  describe "the msn-978954 shape — a behavioral defect filed as an advisory gap" do
    # Every requirement met, and the defect the mission was supposed to
    # fix sitting in `gaps` labelled "minor, non-blocking". A pass verdict
    # is exactly where a false pass hides, so a gap is never folded into
    # the ok pile.
    test "the gap lands in concerns even though nothing is unmet" do
      triage =
        Triage.build(
          validation(%{
            "overall_verdict" => "pass",
            "requirements_met" => for(n <- 1..5, do: %{"req_id" => "FR-#{n}", "met" => true}),
            "gaps" => ["minor: the client still does not retry 5xx responses, non-blocking"]
          })
        )

      assert triage.fails == []
      assert length(triage.oks) == 5

      assert [%{status: :concerns, kind: :gap} = gap] = triage.concerns
      assert gap.title =~ "does not retry 5xx responses"
      assert gap.detail =~ "non-blocking"
    end

    test "every gap gets its own line — none is summarised away" do
      triage =
        Triage.build(validation(%{"gaps" => ["first gap", "second gap", "third gap"]}))

      assert length(triage.concerns) == 3
      assert Enum.map(triage.concerns, & &1.title) == ["first gap", "second gap", "third gap"]
    end

    test "a multi-line gap is titled by its first line and keeps the whole text" do
      triage = Triage.build(validation(%{"gaps" => ["the headline\nthe detail beneath it"]}))

      assert [gap] = triage.concerns
      assert gap.title == "the headline"
      assert gap.detail == "the headline\nthe detail beneath it"
    end
  end

  describe "requirement verdicts" do
    test "an unmet requirement fails, carrying its evidence" do
      triage =
        Triage.build(
          validation(%{
            "requirements_met" => [
              %{"req_id" => "FR-1", "met" => true},
              %{"req_id" => "FR-5", "met" => false, "evidence" => "no retry on 5xx responses"}
            ]
          })
        )

      assert [%{kind: :requirement, status: :fail} = fail] = triage.fails
      assert fail.title == "FR-5 NOT met"
      assert fail.detail == "no retry on 5xx responses"
      assert length(triage.oks) == 1
    end

    test "a flip the factory downgraded fails and says why" do
      triage =
        Triage.build(
          validation(%{
            "requirements_met" => [
              %{
                "req_id" => "FR-5",
                "met" => false,
                "rebuttal_missing" => true,
                "evidence" => "looks implemented to me"
              }
            ]
          })
        )

      assert [%{kind: :contested_flip, status: :fail} = fail] = triage.fails
      assert fail.title =~ "FR-5"
      assert fail.detail =~ "no rebuttal"
      assert fail.detail =~ "downgraded"

      # The validator's case survives next to the verdict that rejected it.
      assert fail.detail =~ "looks implemented to me"
    end

    test "an entry with no verdict at all fails rather than passing quietly" do
      triage = Triage.build(validation(%{"requirements_met" => [%{"req_id" => "FR-5"}]}))

      assert [%{kind: :requirement, status: :fail, title: "FR-5 NOT met"}] = triage.fails
    end

    test "an entry that is not even a map fails" do
      triage = Triage.build(validation(%{"requirements_met" => ["FR-5 is fine"]}))

      assert [%{status: :fail, title: "Unreadable requirement entry"}] = triage.fails
    end

    test "a nameless entry is still rendered, not dropped" do
      triage = Triage.build(validation(%{"requirements_met" => [%{"met" => true}]}))

      assert [%{title: "(unnamed requirement) met"}] = triage.oks
    end

    test "the legacy `id` key is read when `req_id` is absent" do
      triage =
        Triage.build(validation(%{"requirements_met" => [%{"id" => "NFR-2", "met" => true}]}))

      assert [%{title: "NFR-2 met"}] = triage.oks
    end
  end

  describe "the contested register" do
    test "a contested id with no rebutted verdict this round fails" do
      triage =
        Triage.build(
          mission(
            %{"validation" => %{"requirements_met" => [%{"req_id" => "FR-1", "met" => true}]}},
            %{
              contested_requirements: [
                %{"req_id" => "FR-5", "reason" => "no retry on 5xx responses"}
              ]
            }
          )
        )

      assert [%{kind: :contested_open, status: :fail} = fail] = triage.fails
      assert fail.title =~ "FR-5 stands contested"
      assert fail.detail == "no retry on 5xx responses"
    end

    test "a contested id this round rebutted is settled, not reported open" do
      triage =
        Triage.build(
          mission(
            %{
              "validation" => %{
                "requirements_met" => [
                  %{
                    "req_id" => "FR-5",
                    "met" => true,
                    "rebuttal" => "client.ex now retries 5xx three times with backoff"
                  }
                ]
              }
            },
            %{contested_requirements: [%{"req_id" => "FR-5", "reason" => "no retry on 5xx"}]}
          )
        )

      assert triage.fails == []
      assert [%{kind: :contested_rebutted}] = triage.oks
    end

    test "a met:true without a rebuttal does not settle the contest" do
      triage =
        Triage.build(
          mission(
            %{
              "validation" => %{
                "requirements_met" => [%{"req_id" => "FR-5", "met" => true}]
              }
            },
            %{contested_requirements: [%{"req_id" => "FR-5", "reason" => "no retry on 5xx"}]}
          )
        )

      assert [%{kind: :contested_open}] = triage.fails
    end

    test "a register entry with no reason falls back to the standing wording" do
      triage =
        Triage.build(
          mission(%{"validation" => %{}}, %{contested_requirements: [%{"req_id" => "FR-5"}]})
        )

      assert [%{detail: "previously judged unmet"}] = triage.fails
    end

    test "junk in the register is ignored rather than rendered" do
      triage =
        Triage.build(
          mission(%{"validation" => %{}}, %{
            contested_requirements: ["junk", %{"reason" => "no id"}, %{"req_id" => ""}]
          })
        )

      assert triage.fails == []
    end
  end

  describe "ground truth" do
    test "an infra failure on exec_validation is a concern, not a pass" do
      triage =
        Triage.build(
          mission(%{
            "validation" => %{"overall_verdict" => "pass"},
            "exec_validation" => %{"status" => "fail", "infra_failure" => true}
          })
        )

      assert [%{kind: :ground_truth, status: :concerns} = concern] = triage.concerns
      assert concern.detail =~ "run the software yourself"
      assert triage.fails == []
    end

    test "a healthy exec_validation adds nothing" do
      triage =
        Triage.build(
          mission(%{
            "validation" => %{"overall_verdict" => "pass"},
            "exec_validation" => %{"status" => "pass"}
          })
        )

      assert triage.concerns == []
    end
  end

  describe "cross-check override" do
    test "a gate that overrode a pass verdict fails" do
      triage =
        Triage.build(
          validation(%{
            "overall_verdict" => "fail",
            "cross_check_override" => "no implementation commits on the branch"
          })
        )

      assert [%{kind: :cross_check, status: :fail} = fail] = triage.fails
      assert fail.detail == "no implementation commits on the branch"
    end
  end

  describe "nothing to triage" do
    test "a mission with no validation artifact yields the single concerns item" do
      triage = Triage.build(mission(%{}))

      assert triage.fails == []
      assert triage.oks == []
      assert [%{kind: :no_artifact, status: :concerns} = concern] = triage.concerns
      assert concern.title =~ "No validation artifact"
      assert concern.detail =~ "read the mission first"
    end

    test "a mission with no artifacts map at all is the same case" do
      assert [%{kind: :no_artifact}] = Triage.build(%{id: "msn-test"}).concerns
    end

    test "a non-map mission triages to nothing rather than crashing" do
      assert Triage.build(nil) == %{fails: [], concerns: [], oks: []}
    end
  end

  describe "tally/1" do
    test "pluralises fails and concerns, never `ok`" do
      assert Triage.tally(%{fails: [], concerns: [], oks: []}) == "0 fails · 0 concerns · 0 ok"

      assert Triage.tally(%{fails: [:a], concerns: [:a], oks: [:a]}) ==
               "1 fail · 1 concern · 1 ok"

      assert Triage.tally(%{fails: [:a, :b], concerns: [:a, :b], oks: [:a, :b]}) ==
               "2 fails · 2 concerns · 2 ok"
    end
  end

  describe "grouping" do
    test "every item carries the full shape the panel renders" do
      triage = Triage.build(ac0539())

      for item <- triage.fails ++ triage.concerns ++ triage.oks do
        assert item.status in [:ok, :concerns, :fail]
        assert is_atom(item.kind)
        assert is_binary(item.title)
        assert is_nil(item.detail) or is_binary(item.detail)
        assert is_nil(item.rebuttal) or is_binary(item.rebuttal)
      end
    end

    test "a mission that trips every rule reports each source once" do
      triage =
        Triage.build(
          mission(
            %{
              "validation" => %{
                "requirements_met" => [
                  %{"req_id" => "FR-1", "met" => true},
                  %{"req_id" => "FR-2", "met" => false},
                  %{"req_id" => "FR-3", "met" => false, "rebuttal_missing" => true}
                ],
                "gaps" => ["a gap"],
                "cross_check_override" => "no commits"
              },
              "exec_validation" => %{"infra_failure" => true}
            },
            %{contested_requirements: [%{"req_id" => "FR-9", "reason" => "still broken"}]}
          )
        )

      assert kinds(triage.fails) == [:requirement, :contested_flip, :cross_check, :contested_open]
      assert kinds(triage.concerns) == [:gap, :ground_truth]
      assert kinds(triage.oks) == [:requirement]
    end
  end
end
