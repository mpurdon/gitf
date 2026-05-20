defmodule GiTF.Trust.SectorMergeRateTest do
  use ExUnit.Case, async: false

  alias GiTF.Archive
  alias GiTF.Trust

  setup do
    # Refresh the app-level Archive (a prior StoreCase test may have
    # torn down its data_dir while leaving the process pointing at it).
    GiTF.Test.StoreHelper.restore_app_store()

    # Clean :mission_outcomes + :model_reputation caches between tests
    Enum.each(Archive.all(:mission_outcomes), fn o -> Archive.delete(:mission_outcomes, o.id) end)

    Archive.all(:model_reputation)
    |> Enum.filter(fn r -> is_binary(r.id) and String.contains?(r.id, ":merge") end)
    |> Enum.each(fn r -> Archive.delete(:model_reputation, r.id) end)

    :ok
  end

  defp seed_outcome(sector_id, category) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Archive.insert(:mission_outcomes, %{
      mission_id: "msn-#{:erlang.unique_integer([:positive])}",
      sector_id: sector_id,
      outcome_category: category,
      tracking_stopped: true,
      pr_state: "merged",
      updated_at: now,
      first_tracked_at: now,
      reviews: [],
      revert_detected: category == :merged_reverted,
      changes_requested_count: 0,
      poll_count: 1
    })
  end

  describe "sector_merge_rate/1" do
    test "nil when no outcomes" do
      assert Trust.sector_merge_rate("sec-empty") == nil
    end

    test "computes rate = merged / terminal" do
      for _ <- 1..3, do: seed_outcome("sec-A", :merged_clean)
      seed_outcome("sec-A", :merged_reverted)

      rep = Trust.sector_merge_rate("sec-A")
      assert rep.sample_count == 4
      assert rep.rate == 0.75
      assert rep.reverted_count == 1
      assert rep.window_days == 30
    end

    test "cached on second call" do
      seed_outcome("sec-B", :merged_clean)
      first = Trust.sector_merge_rate("sec-B")

      # Seed another outcome, but the cache should return the stale value
      seed_outcome("sec-B", :merged_reverted)
      second = Trust.sector_merge_rate("sec-B")

      assert first.sample_count == second.sample_count

      # Invalidating forces recomputation
      Trust.invalidate_merge_cache(%{sector_id: "sec-B", ops: []})
      fresh = Trust.sector_merge_rate("sec-B")
      assert fresh.sample_count == 2
    end
  end
end
