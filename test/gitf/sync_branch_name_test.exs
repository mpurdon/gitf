defmodule GiTF.SyncBranchNameTest do
  @moduledoc """
  The mission branch name is what a human types to verify the factory's work,
  so it is a contract: it must identify the run and describe the feature.
  """
  use ExUnit.Case, async: true

  alias GiTF.Sync

  describe "branch_slug/1" do
    test "leads with the mission id so the branch maps back to a run" do
      slug = Sync.branch_slug(%{id: "msn-ff3fc6", name: "add-approve-messages"})
      assert String.starts_with?(slug, "msn-ff3fc6-")
    end

    test "falls back to the mission name when no requirements artifact exists" do
      assert Sync.branch_slug(%{id: "msn-aaaaaa", name: "sort-the-user-list"}) ==
               "msn-aaaaaa-sort-the-user-list"
    end

    test "keeps short names whole rather than clipping the last word" do
      assert Sync.branch_slug(%{id: "msn-bbbbbb", name: "approve-messages"}) ==
               "msn-bbbbbb-approve-messages"
    end

    test "truncates long names on a word boundary" do
      long = "in-src-windows-settings-view-tsx-show-the-total-number-of-tracked-users"
      slug = Sync.branch_slug(%{id: "msn-cccccc", name: long})

      refute String.ends_with?(slug, "-")
      # The trailing fragment is a whole word, not a clipped one.
      last_word = slug |> String.split("-") |> List.last()
      assert last_word in String.split(long, "-")
    end

    test "downcases and strips characters git refuses in a ref" do
      slug = Sync.branch_slug(%{id: "msn-dddddd", name: "Fix: Settings ~ Repos [beta]"})

      refute slug =~ ~r/[A-Z\s:~^?*\[\]\\]/
      assert String.starts_with?(slug, "msn-dddddd-fix")
    end

    test "degrades to the bare id rather than an empty segment" do
      assert Sync.branch_slug(%{id: "msn-eeeeee", name: ""}) == "msn-eeeeee-untitled"
    end

    test "still produces a usable slug when the mission has no id" do
      assert Sync.branch_slug(%{name: "approve-messages"}) == "approve-messages"
    end
  end

  describe "quest_target/2" do
    test "cuts a fresh branch off main for an ordinary mission" do
      assert {"mission/msn-aaaaaa-add-a-thing", "main"} =
               Sync.quest_target(%{id: "msn-aaaaaa", name: "add-a-thing"}, "main")
    end

    test "a follow-up builds on the branch under review and keeps its name" do
      # Same branch for both: the PR's head must gain commits, not be
      # replaced by a second branch that opens a second PR.
      mission = %{id: "msn-bbbbbb", name: "address-review", target_branch: "mission/msn-x-feature"}

      assert {"mission/msn-x-feature", "mission/msn-x-feature"} =
               Sync.quest_target(mission, "main")
    end

    test "an empty target_branch falls back to a fresh branch" do
      assert {"mission/msn-cccccc-x", "main"} =
               Sync.quest_target(%{id: "msn-cccccc", name: "x", target_branch: ""}, "main")
    end

    test "a review follow-up refuses to cut a new branch" do
      # Falling back here would open a SECOND pull request carrying the answer
      # to a review left on the first. Surface the bug instead.
      assert_raise ArgumentError, ~r/refusing to cut a new branch/, fn ->
        Sync.quest_target(%{id: "msn-dddddd", name: "x", source: "pr_review"}, "main")
      end
    end

    test "a review follow-up with a head branch builds on it" do
      mission = %{id: "msn-eeeeee", name: "x", source: "pr_review", target_branch: "feature/x"}
      assert {"feature/x", "feature/x"} = Sync.quest_target(mission, "main")
    end
  end
end
