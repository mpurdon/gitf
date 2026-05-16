defmodule GiTF.Phases.ScoringTest do
  use GiTF.StoreCase

  alias GiTF.Phases.Scoring

  defp insert_mission!(attrs) do
    {:ok, m} =
      GiTF.Archive.insert(
        :missions,
        Map.merge(
          %{
            name: "s",
            goal: "x",
            status: "completed",
            post_processing_status: "pending",
            sector_id: "fe",
            artifacts: %{},
            ops: []
          },
          attrs
        )
      )

    m
  end

  describe "verdict/2" do
    test "advance when the scoring artifact is present" do
      m = insert_mission!(%{})
      assert Scoring.verdict(m, %{"overall_score" => 90}) == :advance
    end

    test "terminal_fail when no artifact and ≥3 failed scoring ops (post-processing exhausted)" do
      m =
        insert_mission!(%{
          ops: [
            %{phase_job: true, phase: "scoring", status: "failed"},
            %{phase_job: true, phase: "scoring", status: "failed"},
            %{phase_job: true, phase: "scoring", status: "failed"}
          ]
        })

      assert Scoring.verdict(m, nil) == :terminal_fail
    end

    test "wait when no artifact and < 3 failed scoring ops" do
      m =
        insert_mission!(%{
          ops: [%{phase_job: true, phase: "scoring", status: "failed"}]
        })

      assert Scoring.verdict(m, nil) == :wait
    end
  end

  describe "terminal/3" do
    test ":complete flips post_processing_status to done (via finish_scored)" do
      m = insert_mission!(%{artifacts: %{"scoring" => %{"overall_score" => 85}}})
      Scoring.terminal(m, :complete, %{"overall_score" => 85})
      reloaded = GiTF.Archive.get(:missions, m.id)
      assert reloaded.post_processing_status == "done"
      assert reloaded.current_phase == "completed"
    end

    test ":retries_exhausted flips post_processing_status to failed (mission stays user-visible completed)" do
      m = insert_mission!(%{status: "completed"})
      Scoring.terminal(m, :retries_exhausted, nil)
      reloaded = GiTF.Archive.get(:missions, m.id)
      # Mission remains user-visibly "completed"; post_processing is the
      # one that flipped to "failed".
      assert reloaded.status == "completed"
      assert reloaded.post_processing_status == "failed"
    end
  end
end
