defmodule GiTF.MissionsPostProcessingTest do
  @moduledoc """
  Tests for M3b — async post-processing helpers on `GiTF.Missions`.

  After publish lands the user-visible "completed" status while scoring +
  learning continue in the background. The mission's `status` and
  `current_phase` deliberately diverge between `mark_user_visible_completed/1`
  and `mark_post_processing_done/1` (or `mark_post_processing_failed/2`).
  """
  use GiTF.StoreCase

  alias GiTF.Missions
  alias GiTF.Archive

  setup do
    {:ok, sector} =
      Archive.insert(:sectors, %{
        name: "post-proc-test-sector-#{:erlang.unique_integer([:positive])}"
      })

    {:ok, mission} = Missions.create(%{goal: "ship a small fix", sector_id: sector.id})

    # Simulate having reached the publish phase before post-processing kicks in.
    {:ok, _} =
      Archive.update(:missions, mission.id, fn m ->
        Map.put(m, :current_phase, "publish")
      end)

    {:ok, mission} = Missions.get(mission.id)
    %{mission: mission}
  end

  describe "mark_user_visible_completed/1" do
    test "sets status=completed and post_processing_status=pending without advancing current_phase",
         %{mission: mission} do
      {:ok, _} = Missions.mark_user_visible_completed(mission.id)

      {:ok, updated} = Missions.get(mission.id)
      assert updated.status == "completed"
      assert updated.post_processing_status == "pending"
      # current_phase intentionally left untouched so the orchestrator's
      # phase pipeline keeps driving scoring.
      assert updated.current_phase == "publish"
    end
  end

  describe "mark_post_processing_done/1" do
    test "advances current_phase to completed and flips post_processing_status",
         %{mission: mission} do
      {:ok, _} = Missions.mark_user_visible_completed(mission.id)

      # Move to scoring as the orchestrator would
      {:ok, _} =
        Archive.update(:missions, mission.id, fn m ->
          Map.put(m, :current_phase, "scoring")
        end)

      {:ok, _} = Missions.mark_post_processing_done(mission.id)

      {:ok, updated} = Missions.get(mission.id)
      assert updated.status == "completed"
      assert updated.current_phase == "completed"
      assert updated.post_processing_status == "done"
    end
  end

  describe "mark_post_processing_failed/2" do
    test "advances phase to completed but keeps user-visible status=completed",
         %{mission: mission} do
      {:ok, _} = Missions.mark_user_visible_completed(mission.id)

      {:ok, _} =
        Archive.update(:missions, mission.id, fn m ->
          Map.put(m, :current_phase, "scoring")
        end)

      {:ok, _} = Missions.mark_post_processing_failed(mission.id, "out of budget")

      {:ok, updated} = Missions.get(mission.id)
      assert updated.status == "completed"
      assert updated.current_phase == "completed"
      assert updated.post_processing_status == "failed"
    end
  end

  describe "mark_post_processing_failed/2 from non-scoring phase" do
    test "records the transition and flips status fields", %{mission: mission} do
      # current_phase is still "publish" (setup default) — never entered scoring
      {:ok, _} = Missions.mark_post_processing_failed(mission.id, "provider down")

      {:ok, updated} = Missions.get(mission.id)
      assert updated.current_phase == "completed"
      assert updated.status == "completed"
      assert updated.post_processing_status == "failed"
    end
  end

  describe ":not_found on unknown mission_id" do
    test "mark_user_visible_completed returns :not_found" do
      assert {:error, :not_found} = Missions.mark_user_visible_completed("msn-does-not-exist")
    end

    test "mark_post_processing_done returns :not_found" do
      assert {:error, :not_found} = Missions.mark_post_processing_done("msn-does-not-exist")
    end

    test "mark_post_processing_failed returns :not_found" do
      assert {:error, :not_found} =
               Missions.mark_post_processing_failed("msn-does-not-exist", "boom")
    end
  end

  describe "update_status! terminal-state guard during post-processing" do
    test "does not regress status='completed' while phase is still 'scoring'",
         %{mission: mission} do
      {:ok, _} = Missions.mark_user_visible_completed(mission.id)

      {:ok, _} =
        Archive.update(:missions, mission.id, fn m ->
          Map.put(m, :current_phase, "scoring")
        end)

      # Recompute status — the terminal-state guard should keep it at "completed"
      # even though no impl ops exist (which would otherwise compute "pending").
      {:ok, _} = Missions.update_status!(mission.id)

      {:ok, updated} = Missions.get(mission.id)
      assert updated.status == "completed"
      assert updated.post_processing_status == "pending"
    end
  end
end
