defmodule GiTF.MissionsIssueRefTest do
  @moduledoc """
  Tests for GH-issue-reference parsing + duplicate detection (task #32).

  When a mission is created from an issue-fix goal, we want the issue
  linkage to be structured (not just lurking in the goal text) so:

    * duplicate missions for the same issue are detectable
    * downstream workflows (PR body, webhook responses) can cite the issue
    * MCP consumers can filter by issue
  """
  use GiTF.StoreCase

  alias GiTF.Missions
  alias GiTF.Archive

  setup do
    {:ok, sector} =
      Archive.insert(:sectors, %{
        name: "issue-ref-test-sector-#{:erlang.unique_integer([:positive])}"
      })

    %{sector: sector}
  end

  describe "parse_issue_ref/1 — recognised formats" do
    test "owner/repo#N fully qualified" do
      assert %{"owner" => "acme", "repo" => "web", "number" => 42} =
               Missions.parse_issue_ref("fix acme/web#42: login broken")
    end

    test "https://github.com/owner/repo/issues/N" do
      ref = Missions.parse_issue_ref("see https://github.com/foo/bar/issues/7 for context")
      assert ref == %{"owner" => "foo", "repo" => "bar", "number" => 7}
    end

    test "pull URL also works" do
      ref = Missions.parse_issue_ref("https://github.com/foo/bar/pull/99 needs rebase")
      assert ref["number"] == 99
    end

    test "GH-N bare form" do
      assert %{"number" => 40} = Missions.parse_issue_ref("GH-40 label change")
    end

    test "lowercase gh-N" do
      assert %{"number" => 40} = Missions.parse_issue_ref("gh-40 label change")
    end

    test "#N bare form" do
      assert %{"number" => 123} = Missions.parse_issue_ref("Track #123 for next week")
    end
  end

  describe "parse_issue_ref/1 — rejections" do
    test "nil returns nil" do
      assert Missions.parse_issue_ref(nil) == nil
    end

    test "empty string returns nil" do
      assert Missions.parse_issue_ref("") == nil
    end

    test "goal without any issue reference returns nil" do
      assert Missions.parse_issue_ref("refactor the auth module") == nil
    end

    test "does not confuse a standalone number" do
      assert Missions.parse_issue_ref("bump version to 42.0") == nil
    end
  end

  describe "Missions.create/1 populates issue_ref" do
    test "from goal text containing GH-N", %{sector: sector} do
      {:ok, mission} =
        Missions.create(%{
          goal: "Fix GH-40: Collapse all button label",
          sector_id: sector.id
        })

      assert mission.issue_ref == %{"number" => 40}
    end

    test "explicit issue_ref in attrs overrides the parsed one", %{sector: sector} do
      explicit = %{"owner" => "foo", "repo" => "bar", "number" => 7}

      {:ok, mission} =
        Missions.create(%{
          goal: "Fix GH-40: Collapse all",
          sector_id: sector.id,
          issue_ref: explicit
        })

      assert mission.issue_ref == explicit
    end

    test "goal with no recognised reference leaves issue_ref nil", %{sector: sector} do
      {:ok, mission} =
        Missions.create(%{
          goal: "Refactor the auth module",
          sector_id: sector.id
        })

      assert mission.issue_ref == nil
    end
  end

  describe "find_by_issue_ref/2" do
    test "returns missions with matching number in same sector", %{sector: sector} do
      {:ok, m1} = Missions.create(%{goal: "Fix GH-40", sector_id: sector.id})
      {:ok, _m2} = Missions.create(%{goal: "Fix GH-41", sector_id: sector.id})

      [found] = Missions.find_by_issue_ref(sector.id, %{"number" => 40})
      assert found.id == m1.id
    end

    test "ignores missions in other sectors", %{sector: sector} do
      {:ok, other} = Archive.insert(:sectors, %{name: "other-sector"})
      {:ok, _} = Missions.create(%{goal: "Fix GH-40", sector_id: other.id})

      assert Missions.find_by_issue_ref(sector.id, %{"number" => 40}) == []
    end

    test "fully qualified ref matches only the same owner/repo", %{sector: sector} do
      {:ok, _m1} =
        Missions.create(%{
          goal: "bug",
          sector_id: sector.id,
          issue_ref: %{"owner" => "foo", "repo" => "bar", "number" => 5}
        })

      {:ok, m2} =
        Missions.create(%{
          goal: "bug",
          sector_id: sector.id,
          issue_ref: %{"owner" => "baz", "repo" => "qux", "number" => 5}
        })

      [found] =
        Missions.find_by_issue_ref(sector.id, %{"owner" => "baz", "repo" => "qux", "number" => 5})

      assert found.id == m2.id
    end

    test "bare ref on stored mission matches by number within sector", %{sector: sector} do
      {:ok, m1} = Missions.create(%{goal: "Fix GH-99", sector_id: sector.id})

      [found] =
        Missions.find_by_issue_ref(sector.id, %{"owner" => "any", "repo" => "any", "number" => 99})

      assert found.id == m1.id
    end

    test "excludes failed/closed missions", %{sector: sector} do
      {:ok, m1} = Missions.create(%{goal: "Fix GH-7", sector_id: sector.id})
      Archive.update(:missions, m1.id, fn m -> Map.put(m, :status, "failed") end)

      assert Missions.find_by_issue_ref(sector.id, %{"number" => 7}) == []
    end

    test "nil ref returns []", %{sector: sector} do
      assert Missions.find_by_issue_ref(sector.id, nil) == []
    end
  end
end
