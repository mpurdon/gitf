defmodule GiTF.Ghost.ResolutionProofTest do
  @moduledoc """
  Run 5's post-mortem in test form: the gate that let a lying resolution
  through did so by RESCUING to "clean" on every path it could not
  evaluate. Each unverifiable shape below is one of those paths.
  """
  use GiTF.StoreCase

  alias GiTF.{Archive, Ghost.ResolutionProof}

  # Absolute path so subprocess spawns survive other tests' temporary PATH
  # narrowing (env vars are process-global).
  @git System.find_executable("git")

  setup do
    worktree =
      Path.join(System.tmp_dir!(), "gitf_proof_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(worktree)
    on_exit(fn -> File.rm_rf(worktree) end)

    git = fn args -> System.cmd(@git, args, cd: worktree, stderr_to_stdout: true) end
    git.(["init", "-q", "-b", "main"])
    git.(["config", "user.email", "t@t.dev"])
    git.(["config", "user.name", "t"])
    File.write!(Path.join(worktree, "a.ex"), "defmodule A do\nend\n")
    git.(["add", "-A"])
    git.(["commit", "-qm", "init"])

    {:ok, shell} =
      Archive.insert(:shells, %{
        sector_id: "sec-1",
        ghost_id: "ghost-1",
        worktree_path: worktree,
        branch: "ghost/ghost-1",
        status: "active"
      })

    %{worktree: worktree, shell: shell}
  end

  defp verify(shell_id, files) do
    ResolutionProof.verify(%{
      op_id: "op-1",
      ghost_id: "ghost-1",
      shell_id: shell_id,
      files: files
    })
  end

  describe "verify/1 — the proof holds" do
    test "clean target files pass", %{shell: shell} do
      assert :ok = verify(shell.id, ["a.ex"])
    end
  end

  describe "verify/1 — verified negative" do
    test "a file still carrying markers fails with the file named", %{
      worktree: wt,
      shell: shell
    } do
      File.write!(Path.join(wt, "a.ex"), """
      <<<<<<< HEAD
      one
      =======
      two
      >>>>>>> ghost/other
      """)

      assert {:markers, ["a.ex"]} = verify(shell.id, ["a.ex"])
      assert ResolutionProof.failure_reason({:markers, ["a.ex"]}) =~ "markers remain in: a.ex"
    end
  end

  describe "verify/1 — fails CLOSED on every non-verifiable path" do
    test "a missing shell record is not a pass" do
      assert {:unverifiable, why} = verify("shl-does-not-exist", ["a.ex"])
      assert why =~ "not found"
    end

    test "a nil shell_id is not a pass" do
      assert {:unverifiable, _} = verify(nil, ["a.ex"])
    end

    test "a shell with no worktree path is not a pass" do
      {:ok, shell} =
        Archive.insert(:shells, %{sector_id: "sec-1", ghost_id: "g", worktree_path: nil})

      assert {:unverifiable, why} = verify(shell.id, ["a.ex"])
      assert why =~ "no worktree path"
    end

    test "a pruned worktree is not a pass", %{worktree: wt, shell: shell} do
      File.rm_rf!(wt)

      assert {:unverifiable, why} = verify(shell.id, ["a.ex"])
      assert why =~ "not on disk"
    end

    test "an empty target-file list is not a pass", %{shell: shell} do
      assert {:unverifiable, why} = verify(shell.id, [])
      assert why =~ "no target files"
    end

    # The hole UNDER the gate: `Git.conflict_marker_files/2` returns [] both
    # when the tree is clean and when git could not run at all, and [] is
    # the proof. A directory that exists but is not a repository is the
    # cheapest reproduction of "git failed".
    test "a worktree git cannot scan is not a pass" do
      dir = Path.join(System.tmp_dir!(), "gitf_norepo_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "a.ex"), "x")
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, shell} =
        Archive.insert(:shells, %{sector_id: "sec-1", ghost_id: "g2", worktree_path: dir})

      assert {:unverifiable, why} = verify(shell.id, ["a.ex"])
      assert why =~ "git grep"
    end

    test "every unverifiable verdict produces the documented failure reason" do
      reason = ResolutionProof.failure_reason({:unverifiable, "worktree /x is not on disk"})
      assert reason == "resolution proof could not be verified (worktree /x is not on disk)"
    end

    test "a holding proof produces no failure reason" do
      assert ResolutionProof.failure_reason(:ok) == nil
    end
  end
end
