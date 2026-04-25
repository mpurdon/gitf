defmodule GiTF.Outcomes.AnalyzerTest do
  use ExUnit.Case, async: true

  alias GiTF.Outcomes.Analyzer

  @now ~U[2026-04-23 12:00:00Z]

  defp base(overrides) do
    Map.merge(
      %{
        pr_state: "open",
        pr_merged_at: nil,
        revert_detected: false,
        changes_requested_count: 0,
        first_tracked_at: @now
      },
      overrides
    )
  end

  describe "categorize/2" do
    test "revert trumps everything" do
      assert Analyzer.categorize(base(%{pr_state: "merged", revert_detected: true}), @now) ==
               :merged_reverted

      assert Analyzer.categorize(base(%{pr_state: "open", revert_detected: true}), @now) ==
               :merged_reverted
    end

    test "merged without revert is merged_clean" do
      assert Analyzer.categorize(base(%{pr_state: "merged"}), @now) == :merged_clean

      # Merged-at set without explicit state still counts as merged
      assert Analyzer.categorize(
               base(%{pr_state: nil, pr_merged_at: ~U[2026-04-23 11:00:00Z]}),
               @now
             ) == :merged_clean
    end

    test "closed-not-merged is closed_unmerged" do
      assert Analyzer.categorize(base(%{pr_state: "closed"}), @now) == :closed_unmerged
    end

    test "open + changes requested" do
      assert Analyzer.categorize(
               base(%{pr_state: "open", changes_requested_count: 1}),
               @now
             ) == :changes_requested
    end

    test "open past 72h is stale" do
      old = DateTime.add(@now, -(72 * 3600 + 60), :second)
      assert Analyzer.categorize(base(%{pr_state: "open", first_tracked_at: old}), @now) == :stale
    end

    test "open within window is pending" do
      recent = DateTime.add(@now, -3600, :second)

      assert Analyzer.categorize(
               base(%{pr_state: "open", first_tracked_at: recent}),
               @now
             ) == :pending
    end

    test "is case-insensitive on state" do
      assert Analyzer.categorize(base(%{pr_state: "MERGED"}), @now) == :merged_clean
      assert Analyzer.categorize(base(%{pr_state: "Closed"}), @now) == :closed_unmerged
    end
  end

  describe "stale?/2" do
    test "true only past 72h" do
      old = DateTime.add(@now, -(72 * 3600 + 1), :second)
      assert Analyzer.stale?(%{first_tracked_at: old}, @now) == true

      recent = DateTime.add(@now, -3600, :second)
      assert Analyzer.stale?(%{first_tracked_at: recent}, @now) == false
    end

    test "false when no timestamp" do
      assert Analyzer.stale?(%{}, @now) == false
    end
  end
end
