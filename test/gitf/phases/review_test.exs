defmodule GiTF.Phases.ReviewTest do
  @moduledoc """
  Verifies that `GiTF.Phases.Review` implements the Phase behaviour
  semantics: pass/fail verdict from the artifact's `approved` boolean,
  and the `before_advance` side effect promotes the selected design
  variant onto the canonical `design` artifact key.
  """

  use GiTF.StoreCase

  alias GiTF.Archive
  alias GiTF.Phases.Review

  describe "verdict/1" do
    test ":pass when approved is true" do
      assert Review.verdict(%{"approved" => true}) == :pass
    end

    test ":fail when approved is false" do
      assert Review.verdict(%{"approved" => false}) == :fail
    end

    test ":inconclusive when approved is missing" do
      assert Review.verdict(%{"comment" => "..."}) == :inconclusive
    end
  end

  describe "before_advance/3 — design promotion" do
    setup do
      {:ok, m} =
        Archive.insert(:missions, %{
          name: "test",
          goal: "x",
          status: "active",
          sector_id: "fe",
          current_phase: "review",
          artifacts: %{}
        })

      :ok = GiTF.Missions.store_artifact(m.id, "design_minimal", %{"approach" => "minimal"}) |> elem(0) |> case do
        :ok -> :ok
        _ -> :ok
      end

      {:ok, _} = GiTF.Missions.store_artifact(m.id, "design_minimal", %{"approach" => "minimal"})
      {:ok, _} = GiTF.Missions.store_artifact(m.id, "design_normal", %{"approach" => "normal"})
      {:ok, _} = GiTF.Missions.store_artifact(m.id, "design_complex", %{"approach" => "complex"})

      %{mission: Archive.get(:missions, m.id)}
    end

    test "on :pass promotes the selected variant onto the canonical key", %{mission: mission} do
      review = %{"approved" => true, "selected_design" => "complex"}
      :ok = Review.before_advance(mission, :pass, review)

      assert %{"approach" => "complex"} = GiTF.Missions.get_artifact(mission.id, "design")
    end

    test "on :advance (exhaustion fallback) also promotes the selected variant", %{mission: mission} do
      review = %{"approved" => false, "selected_design" => "minimal"}
      :ok = Review.before_advance(mission, :advance, review)

      assert %{"approach" => "minimal"} = GiTF.Missions.get_artifact(mission.id, "design")
    end

    test "defaults to 'normal' when selected_design is missing", %{mission: mission} do
      review = %{"approved" => true}
      :ok = Review.before_advance(mission, :pass, review)

      assert %{"approach" => "normal"} = GiTF.Missions.get_artifact(mission.id, "design")
    end

    test "no-op on :fail (don't promote until we exhaust or pass)", %{mission: mission} do
      review = %{"approved" => false, "selected_design" => "minimal"}
      :ok = Review.before_advance(mission, :fail, review)

      assert nil == GiTF.Missions.get_artifact(mission.id, "design")
    end
  end
end
