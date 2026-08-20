defmodule GiTF.Phases.ReviewCarryforwardTest do
  use GiTF.StoreCase

  alias GiTF.Phases.Review

  defp mission!(artifacts \\ %{}) do
    {:ok, m} =
      GiTF.Archive.insert(:missions, %{name: "cf", goal: "g", artifacts: artifacts})

    m
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
