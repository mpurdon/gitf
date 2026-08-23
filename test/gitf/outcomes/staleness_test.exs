defmodule GiTF.Outcomes.StalenessTest do
  @moduledoc """
  Staleness retires PRs nothing is happening to. Anchored on first_tracked_at
  it retired them for merely being OLD — which abandoned exactly the ones
  becoming interesting. A change request arrived on PR #8 an hour after its
  72h elapsed; the tracker had already stopped watching, so the review was
  never seen and the follow-up never ran.
  """
  use ExUnit.Case, async: true

  alias GiTF.Outcomes.Analyzer

  defp ago(hours), do: DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

  test "an old PR with recent activity is NOT stale" do
    # The regression that cost a real review.
    outcome = %{first_tracked_at: ago(100), last_activity_at: ago(1)}
    refute Analyzer.stale?(outcome)
  end

  test "a quiet PR is stale even if tracking started recently" do
    outcome = %{first_tracked_at: ago(80), last_activity_at: ago(80)}
    assert Analyzer.stale?(outcome)
  end

  test "activity inside the window keeps it alive indefinitely" do
    # A long-running PR reviewed every few days must never age out.
    outcome = %{first_tracked_at: ago(500), last_activity_at: ago(10)}
    refute Analyzer.stale?(outcome)
  end

  test "falls back to first_tracked_at when activity was never recorded" do
    # Records written before last_activity_at existed must still age out
    # rather than being tracked forever.
    assert Analyzer.stale?(%{first_tracked_at: ago(100)})
    refute Analyzer.stale?(%{first_tracked_at: ago(1)})
  end

  test "a record with neither anchor is not stale" do
    refute Analyzer.stale?(%{})
  end

  test "categorization follows the same anchor" do
    fresh = %{
      pr_state: "open",
      first_tracked_at: ago(100),
      last_activity_at: ago(1),
      changes_requested_count: 0
    }

    refute Analyzer.categorize(fresh, DateTime.utc_now()) == :stale
  end
end
