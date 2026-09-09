defmodule GiTF.Phases.ReviewCarryforwardTest do
  use GiTF.StoreCase

  alias GiTF.Phases.Review

  # The hook promotes the reviewer's pick (default "normal"); the fixture
  # carries one so the promotion is not what these tests exercise.
  defp mission!(artifacts \\ %{}) do
    {:ok, m} =
      GiTF.Archive.insert(:missions, %{
        name: "cf",
        goal: "g",
        artifacts: Map.merge(%{"design_normal" => %{"approach" => "x"}}, artifacts)
      })

    m
  end

  test "with several designs, a pick that has no artifact refuses the advance" do
    {:ok, m} =
      GiTF.Archive.insert(:missions, %{
        name: "cf",
        goal: "g",
        artifacts: %{
          "design_minimal" => %{"approach" => "a"},
          "design_complex" => %{"approach" => "b"}
        }
      })

    assert {:error, :selected_variant_missing} =
             Review.before_advance(m, :pass, %{"approved" => true, "selected_design" => "normal"})

    # Unnamed among several: "normal" is the historic default; absent, refuse.
    assert {:error, :selected_variant_missing} =
             Review.before_advance(m, :pass, %{"approved" => true})
  end

  test "with no design at all the advance is refused" do
    {:ok, m} = GiTF.Archive.insert(:missions, %{name: "cf", goal: "g", artifacts: %{}})

    assert {:error, :selected_variant_missing} =
             Review.before_advance(m, :pass, %{"approved" => true, "selected_design" => "normal"})
  end

  test "the one design drawn is the reviewed design, named or not" do
    # A single-strategy round (fast mode, or 'moderate' complexity) draws
    # design_minimal and the reviewer never names a pick — msn-272e35
    # stalled here on 2026-09-09.
    {:ok, m} =
      GiTF.Archive.insert(:missions, %{
        name: "cf",
        goal: "g",
        artifacts: %{"design_minimal" => %{"approach" => "only"}}
      })

    :ok = Review.before_advance(m, :pass, %{"approved" => true})
    assert GiTF.Missions.get_artifact(m.id, "design") == %{"approach" => "only"}

    # A pick the reviewer NAMED that is not there is a different matter.
    assert {:error, :selected_variant_missing} =
             Review.before_advance(m, :pass, %{"approved" => true, "selected_design" => "normal"})
  end

  test "an overruled review records its objection for downstream" do
    mission = mission!()
    artifact = %{"approved" => false, "summary" => "The drawer never persists priority."}

    :ok = Review.before_advance(mission, :advance, artifact)

    {:ok, reloaded} = GiTF.Missions.get(mission.id)
    assert Review.unresolved_objection(reloaded) =~ "never persists priority"
  end

  test "a review that PASSED leaves no objection behind" do
    mission = mission!()
    artifact = %{"approved" => true, "summary" => "Looks good."}

    :ok = Review.before_advance(mission, :pass, artifact)

    {:ok, reloaded} = GiTF.Missions.get(mission.id)
    assert Review.unresolved_objection(reloaded) == nil
  end

  test "no objection recorded when there is nothing to say" do
    mission = mission!()
    :ok = Review.before_advance(mission, :advance, %{"approved" => false})

    {:ok, reloaded} = GiTF.Missions.get(mission.id)
    assert Review.unresolved_objection(reloaded) == nil
  end
end
