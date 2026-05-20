defmodule GiTF.TournamentTest do
  use ExUnit.Case, async: true

  alias GiTF.Tournament

  describe "configured_attempts/0" do
    test "defaults to 1 when no override" do
      Application.delete_env(:gitf, :parallel_impl_attempts)
      assert Tournament.configured_attempts() == 1
      refute Tournament.enabled?()
    end

    test "clamps integer overrides to 1..3" do
      Application.put_env(:gitf, :parallel_impl_attempts, 5)
      assert Tournament.configured_attempts() == 3
      assert Tournament.enabled?()
    after
      Application.delete_env(:gitf, :parallel_impl_attempts)
    end

    test "parses string overrides (env var path)" do
      Application.put_env(:gitf, :parallel_impl_attempts, "2")
      assert Tournament.configured_attempts() == 2
    after
      Application.delete_env(:gitf, :parallel_impl_attempts)
    end

    test "garbage value falls back to 1" do
      Application.put_env(:gitf, :parallel_impl_attempts, :weird)
      assert Tournament.configured_attempts() == 1
    after
      Application.delete_env(:gitf, :parallel_impl_attempts)
    end
  end

  describe "variant_ids/1" do
    test "builds v1..vN" do
      assert Tournament.variant_ids(1) == ["v1"]
      assert Tournament.variant_ids(2) == ["v1", "v2"]
      assert Tournament.variant_ids(3) == ["v1", "v2", "v3"]
    end
  end

  describe "running?/1" do
    test "true when mission has 2+ impl_variants" do
      assert Tournament.running?(%{impl_variants: ["v1", "v2"]})
      assert Tournament.running?(%{impl_variants: ["v1", "v2", "v3"]})
    end

    test "false when impl_variants is empty / missing / single" do
      refute Tournament.running?(%{impl_variants: []})
      refute Tournament.running?(%{})
      refute Tournament.running?(%{impl_variants: nil})
      # A single-element variant list is structurally possible but
      # would still be running a "tournament of one" — treat as not
      # running so the panel doesn't render a 1-row tournament table.
      refute Tournament.running?(%{impl_variants: ["v1"]})
    end
  end

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
