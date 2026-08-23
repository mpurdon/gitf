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
end
