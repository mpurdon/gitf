defmodule GiTF.Sync.MergeQuestCheckoutTest do
  @moduledoc """
  After consolidation, the shared clone must be back on main. The next
  mission's triage reads whatever is checked out as "the codebase" — run 4
  of group-pr-list-by-author completed no_work_needed in 80 seconds because
  run 3's publish left the clone on its mission branch, and triage found the
  (unmerged) feature already present with perfect file:line evidence.
  """

  use GiTF.StoreCase

  alias GiTF.Archive

  defp git!(repo, args) do
    {out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    out
  end

  defp git(repo, args) do
    {out, _} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    String.trim(out)
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "gitf_mq_#{:erlang.unique_integer([:positive])}")
    repo = Path.join(tmp, "repo")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(tmp) end)

    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.email", "t@gitf"])
    git!(repo, ["config", "user.name", "t"])
    File.write!(Path.join(repo, "a.txt"), "base\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "initial"])

    git!(repo, ["checkout", "-b", "ghost/ghost-mq1"])
    File.write!(Path.join(repo, "feature.txt"), "work\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "ghost work"])
    git!(repo, ["checkout", "main"])

    {:ok, sector} =
      Archive.insert(:sectors, %{name: "repo", path: repo, sync_strategy: "pr_branch"})

    {:ok, mission} =
      GiTF.Missions.create(%{goal: "consolidation checkout test", sector_id: sector.id})

    {:ok, op} =
      Archive.insert(:ops, %{
        title: "impl",
        mission_id: mission.id,
        sector_id: sector.id,
        status: "done",
        branch: "ghost/ghost-mq1",
        ghost_id: "ghost-mq1"
      })

    # merge_quest reads ops off the mission record.
    {:ok, mission} = Archive.update(:missions, mission.id, &Map.put(&1, :ops, [op]))

    %{repo: repo, mission: mission}
  end

  test "the clone is back on main after consolidation, with the quest branch intact",
       %{repo: repo, mission: mission} do
    assert {:ok, quest_branch} = GiTF.Sync.merge_quest(mission.id)

    # The consolidation happened — the quest branch holds the ghost's work…
    assert git(repo, ["rev-parse", "--verify", quest_branch]) != ""
    assert git(repo, ["show", "#{quest_branch}:feature.txt"]) == "work"

    # …but the WORKING TREE is back where the next mission expects it.
    assert git(repo, ["branch", "--show-current"]) == "main"

    refute File.exists?(Path.join(repo, "feature.txt")),
           "main's working tree must not contain unmerged mission work"
  end
end
