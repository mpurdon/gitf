defmodule GiTF.DebriefTest do
  use ExUnit.Case, async: false

  alias GiTF.Debrief
  alias GiTF.Archive
  alias GiTF.Test.StoreHelper

  setup do
    data_dir = Path.join(System.tmp_dir!(), "gitf_test_debrief_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(data_dir)
    StoreHelper.restart_store!(data_dir)

    on_exit(fn ->
      StoreHelper.stop_store()
      File.rm_rf!(data_dir)
    end)

    :ok
  end

  defp create_quest(opts \\ %{}) do
    goal = Map.get(opts, :goal, "Test mission")
    sector_id = Map.get(opts, :sector_id, "cmb_test")

    sector_attrs = Map.get(opts, :sector, %{})
    sector = Map.merge(%{id: sector_id, path: System.tmp_dir!(), name: "test"}, sector_attrs)
    Archive.insert(:sectors, sector)

    {:ok, mission} = GiTF.Missions.create(%{goal: goal, sector_id: sector_id})
    mission
  end

  describe "start_review/1" do
    test "creates an active review record" do
      mission = create_quest()
      {:ok, review} = Debrief.start_review(mission.id)

      assert review.mission_id == mission.id
      assert review.status == "active"
      assert review.expires_at != nil
    end

    test "review appears in active_reviews" do
      mission = create_quest()
      {:ok, _} = Debrief.start_review(mission.id)

      reviews = Debrief.active_reviews()
      assert length(reviews) == 1
      assert hd(reviews).mission_id == mission.id
    end
  end

  describe "enabled?/1" do
    test "returns false when sector not found" do
      refute Debrief.enabled?("nonexistent")
    end

    test "returns false when debrief not set" do
      Archive.insert(:sectors, %{id: "cmb_no_review", path: "/tmp", name: "no-review"})
      refute Debrief.enabled?("cmb_no_review")
    end

    test "returns true when debrief is true" do
      Archive.insert(:sectors, %{
        id: "cmb_with_review",
        path: "/tmp",
        name: "with-review",
        debrief: true
      })

      assert Debrief.enabled?("cmb_with_review")
    end
  end

  describe "close_review/1" do
    test "marks review as completed" do
      mission = create_quest()
      {:ok, _} = Debrief.start_review(mission.id)

      assert length(Debrief.active_reviews()) == 1

      :ok = Debrief.close_review(mission.id)

      assert length(Debrief.active_reviews()) == 0
    end
  end

  describe "expired?/1" do
    test "returns false for fresh review" do
      review = %{expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)}
      refute Debrief.expired?(review)
    end

    test "returns true for expired review" do
      review = %{expires_at: DateTime.add(DateTime.utc_now(), -1, :second)}
      assert Debrief.expired?(review)
    end
  end

  describe "check_regressions/1" do
    test "returns :clean when no validation command" do
      mission = create_quest()
      {:ok, _} = Debrief.start_review(mission.id)

      assert {:ok, :clean} = Debrief.check_regressions(mission.id)
    end

    test "returns :clean when validation passes" do
      mission = create_quest(%{sector: %{validation_command: "true"}})
      {:ok, _} = Debrief.start_review(mission.id)

      assert {:ok, :clean} = Debrief.check_regressions(mission.id)
    end

    test "returns :regression when validation fails" do
      mission = create_quest(%{sector: %{validation_command: "echo 'test failed' && exit 1"}})
      {:ok, _} = Debrief.start_review(mission.id)

      assert {:ok, :regression, findings} = Debrief.check_regressions(mission.id)
      assert String.contains?(findings, "test failed")
    end
  end

  describe "handle_regression/2" do
    test "creates follow-up mission and updates review" do
      mission = create_quest()
      {:ok, _} = Debrief.start_review(mission.id)

      {:ok, followup} = Debrief.handle_regression(mission.id, "Tests failed")

      assert String.contains?(followup.goal, "Fix regression")
      assert followup.sector_id == mission.sector_id

      # Review should be updated
      assert length(Debrief.active_reviews()) == 0
    end
  end

  describe "Trust.apply_regression_penalty/1" do
    test "marks ops with regression_detected" do
      mission = create_quest()

      {:ok, op} =
        GiTF.Ops.create(%{
          title: "Test op",
          mission_id: mission.id,
          sector_id: mission.sector_id
        })

      # Initially no regression flag
      {:ok, fresh_job} = GiTF.Ops.get(op.id)
      refute Map.get(fresh_job, :regression_detected, false)

      # Apply penalty
      GiTF.Trust.apply_regression_penalty(mission.id)

      # Now regression flag should be set
      {:ok, updated_job} = GiTF.Ops.get(op.id)
      assert Map.get(updated_job, :regression_detected) == true
    end
  end
end
