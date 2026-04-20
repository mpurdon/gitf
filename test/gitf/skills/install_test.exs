defmodule GiTF.Skills.InstallTest do
  use GiTF.StoreCase

  alias GiTF.Skills
  alias GiTF.Skills.Install

  setup do
    worktree = Path.join(System.tmp_dir!(), "gitf_skills_install_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(worktree)
    on_exit(fn -> File.rm_rf!(worktree) end)

    %{worktree: worktree}
  end

  describe "install_into_worktree/2" do
    test "writes skill bodies to .claude/skills/ and bumps applied_count", %{worktree: wt} do
      {:ok, skill} =
        Skills.create(%{
          name: "x",
          description: "d",
          body: "---\nname: x\n---\nbody content",
          scope: :global
        })

      assert [_id] = Install.install_into_worktree([skill], wt)

      file = Path.join([wt, ".claude/skills", "#{skill.id}.md"])
      assert File.exists?(file)
      assert File.read!(file) == "---\nname: x\n---\nbody content"

      reloaded = Skills.get(skill.id)
      assert reloaded.applied_count == 1
    end

    test "is idempotent — second install with identical content does not bump counter", %{worktree: wt} do
      {:ok, skill} = Skills.create(%{name: "y", description: "d", body: "stable", scope: :global})

      Install.install_into_worktree([skill], wt)
      Install.install_into_worktree([skill], wt)

      reloaded = Skills.get(skill.id)
      assert reloaded.applied_count == 1
    end

    test "returns empty list when no skills given", %{worktree: wt} do
      assert [] = Install.install_into_worktree([], wt)
      refute File.exists?(Path.join(wt, ".claude/skills"))
    end

    test "creates .claude/skills directory if absent", %{worktree: wt} do
      File.rm_rf!(Path.join(wt, ".claude"))
      {:ok, skill} = Skills.create(%{name: "z", description: "d", body: "b", scope: :global})

      Install.install_into_worktree([skill], wt)

      assert File.dir?(Path.join(wt, ".claude/skills"))
    end

    test "does not crash on filesystem errors", %{worktree: _wt} do
      # Try to install into a path under a non-existent root
      bad_path = "/nonexistent_root_that_should_not_exist_xyz/wt"
      {:ok, skill} = Skills.create(%{name: "n", description: "d", body: "b", scope: :global})

      assert [] = Install.install_into_worktree([skill], bad_path)
    end
  end
end
