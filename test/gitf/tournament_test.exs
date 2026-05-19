defmodule GiTF.TournamentTest do
  use ExUnit.Case, async: true

  alias GiTF.Tournament

  describe "score/1" do
    test "pass + all requirements met + zero gaps scores 150" do
      artifact = %{
        "overall_verdict" => "pass",
        "requirements_met" => [
          %{"req_id" => "FR-1", "met" => true},
          %{"req_id" => "FR-2", "met" => true}
        ],
        "gaps" => []
      }

      assert %{score: 150.0, verdict: :pass, requirements_met: 2, gaps: 0} =
               Tournament.score(artifact)
    end

    test "pass + half requirements met + zero gaps scores 125" do
      artifact = %{
        "overall_verdict" => "pass",
        "requirements_met" => [
          %{"req_id" => "FR-1", "met" => true},
          %{"req_id" => "FR-2", "met" => false}
        ]
      }

      assert %{score: 125.0, verdict: :pass} = Tournament.score(artifact)
    end

    test "fail + zero gaps + zero requirements scores 0" do
      assert %{score: +0.0, verdict: :fail} =
               Tournament.score(%{"overall_verdict" => "fail"})
    end

    test "gaps subtract 10 each" do
      artifact = %{
        "overall_verdict" => "pass",
        "requirements_met" => [],
        "gaps" => ["a", "b", "c"]
      }

      assert %{score: 70.0, gaps: 3} = Tournament.score(artifact)
    end

    test "cross_check_override disqualifies the variant" do
      artifact = %{
        "overall_verdict" => "fail",
        "cross_check_override" => "no completed impl ops"
      }

      assert %{score: :disqualified, disqualified_reason: reason} = Tournament.score(artifact)
      assert reason =~ "no completed impl ops"
    end

    test "nil artifact yields a disqualified low score" do
      assert %{score: score, disqualified_reason: "no validation artifact"} =
               Tournament.score(nil)

      assert is_number(score) and score < 0
    end
  end

  describe "rank/1" do
    test "orders variants by score descending" do
      mission = %{
        impl_variants: ["v1", "v2", "v3"],
        artifacts: %{
          "validation_v1" => %{
            "overall_verdict" => "pass",
            "requirements_met" => [%{"met" => true}],
            "gaps" => ["minor"]
          },
          "validation_v2" => %{
            "overall_verdict" => "pass",
            "requirements_met" => [%{"met" => true}, %{"met" => true}],
            "gaps" => []
          },
          "validation_v3" => %{"overall_verdict" => "fail"}
        }
      }

      assert [
               %{variant: "v2", score: 150.0},
               %{variant: "v1", score: 140.0},
               %{variant: "v3", score: +0.0}
             ] = Tournament.rank(mission)
    end

    test "ties break in favour of the lower-indexed variant" do
      same_artifact = %{
        "overall_verdict" => "pass",
        "requirements_met" => [%{"met" => true}],
        "gaps" => []
      }

      mission = %{
        impl_variants: ["v1", "v2"],
        artifacts: %{
          "validation_v1" => same_artifact,
          "validation_v2" => same_artifact
        }
      }

      assert [%{variant: "v1"}, %{variant: "v2"}] = Tournament.rank(mission)
    end

    test "disqualified variants sort last regardless of numeric score" do
      mission = %{
        impl_variants: ["v1", "v2"],
        artifacts: %{
          "validation_v1" => %{
            "overall_verdict" => "fail",
            "cross_check_override" => "all .claude/"
          },
          "validation_v2" => %{"overall_verdict" => "fail"}
        }
      }

      assert [%{variant: "v2"}, %{variant: "v1", score: :disqualified}] =
               Tournament.rank(mission)
    end

    test "empty impl_variants returns []" do
      assert [] = Tournament.rank(%{impl_variants: [], artifacts: %{}})
      assert [] = Tournament.rank(%{})
    end
  end

  describe "pick_winner/1" do
    test "returns highest-scoring variant" do
      mission = %{
        impl_variants: ["v1", "v2"],
        artifacts: %{
          "validation_v1" => %{"overall_verdict" => "fail"},
          "validation_v2" => %{
            "overall_verdict" => "pass",
            "requirements_met" => [%{"met" => true}]
          }
        }
      }

      assert {:ok, "v2"} = Tournament.pick_winner(mission)
    end

    test "{:error, :no_variants} when not running a tournament" do
      assert {:error, :no_variants} = Tournament.pick_winner(%{})
      assert {:error, :no_variants} = Tournament.pick_winner(%{impl_variants: []})
    end

    test "{:error, :all_disqualified} when every variant lost the cross-check" do
      mission = %{
        impl_variants: ["v1", "v2"],
        artifacts: %{
          "validation_v1" => %{"cross_check_override" => "no commits"},
          "validation_v2" => %{"cross_check_override" => "all .claude/"}
        }
      }

      assert {:error, :all_disqualified} = Tournament.pick_winner(mission)
    end
  end

  describe "ready?/1" do
    test "true when all variants have a validation artifact" do
      mission = %{
        impl_variants: ["v1", "v2"],
        artifacts: %{
          "validation_v1" => %{"overall_verdict" => "pass"},
          "validation_v2" => %{"overall_verdict" => "fail"}
        }
      }

      assert Tournament.ready?(mission)
    end

    test "false while any variant is still in flight" do
      mission = %{
        impl_variants: ["v1", "v2", "v3"],
        artifacts: %{
          "validation_v1" => %{"overall_verdict" => "pass"},
          "validation_v2" => %{"overall_verdict" => "pass"}
        }
      }

      refute Tournament.ready?(mission)
    end

    test "false when there are no variants" do
      refute Tournament.ready?(%{impl_variants: [], artifacts: %{}})
      refute Tournament.ready?(%{})
    end
  end
end
