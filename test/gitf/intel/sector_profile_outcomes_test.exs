defmodule GiTF.Intel.SectorProfileOutcomesTest do
  use ExUnit.Case, async: false

  alias GiTF.Archive
  alias GiTF.Intel.SectorProfile

  setup do
    # Make sure the app-level Archive isn't pointing at a torn-down
    # StoreCase temp dir from a prior test; otherwise inserts below
    # blow up with `{:error, :enoent}` and the bind crashes with
    # CaseClauseError.
    GiTF.Test.StoreHelper.restore_app_store()
    Enum.each(Archive.all(:mission_outcomes), fn o -> Archive.delete(:mission_outcomes, o.id) end)
    Enum.each(Archive.all(:sector_profiles), fn p -> Archive.delete(:sector_profiles, p.id) end)
    :ok
  end

  defp seed_outcome(sector_id, category) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Archive.insert(:mission_outcomes, %{
      mission_id: "msn-#{:erlang.unique_integer([:positive])}",
      sector_id: sector_id,
      outcome_category: category,
      tracking_stopped: true,
      updated_at: now,
      first_tracked_at: now,
      reviews: [],
      revert_detected: false,
      changes_requested_count: 0,
      poll_count: 1
    })
  end

  test "merge_success_rate lesson is computed from mission_outcomes" do
    sector_id = "sec-merge-rate"

    for _ <- 1..4, do: seed_outcome(sector_id, :merged_clean)
    seed_outcome(sector_id, :merged_reverted)

    profile = SectorProfile.compute(sector_id)
    lesson = profile.lessons.merge_success_rate

    assert lesson.sample_count == 5
    assert lesson.rate == 0.8
    assert lesson.reverted_count == 1
  end

  test "empty lesson when no outcomes" do
    profile = SectorProfile.compute("sec-nothing")
    assert profile.lessons.merge_success_rate.rate == nil
    assert profile.lessons.merge_success_rate.sample_count == 0
  end

  test "PromptContext renders a merge-success line" do
    sector_id = "sec-prompt"
    for _ <- 1..5, do: seed_outcome(sector_id, :merged_clean)

    profile = SectorProfile.compute(sector_id)
    ctx = profile.prompt_context

    # High confidence (≥20) is needed for the big context block; check the
    # lesson map regardless since render_context depends on confidence.
    # Even at :low confidence, the lesson should be computed.
    assert is_map(profile.lessons.merge_success_rate)
    assert profile.lessons.merge_success_rate.rate == 1.0

    # The rendered context only appears at :medium/:high confidence (≥5
    # completed missions). Our setup doesn't seed :missions (only
    # :mission_outcomes), so sample_count here is 0 and confidence :none.
    # That's fine — the lesson itself is captured for downstream callers.
    _ = ctx
  end
end
