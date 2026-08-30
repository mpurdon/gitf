defmodule GiTF.MissionResumeTest do
  @moduledoc """
  Two halves of the same incident: a failed mission's tree was pruned with
  the mission, so hours of merged, type-checked work were destroyed by the
  cleanup that follows `fail_quest` — and there was nothing left to resume
  from even if resuming had existed.

  These tests use a REAL git repo because both halves are claims about git
  refs: that `archive/<mission_id>` survives the worktree it was cut from,
  and that a resumed mission's worktree is checked out at the parent's
  final tree rather than the sector base.
  """
  use GiTF.StoreCase

  alias GiTF.{Archive, Git, Missions, Ops}
  alias GiTF.Major.Topology

  # Absolute path so subprocess spawns survive other tests' temporary PATH
  # narrowing (env vars are process-global).
  @git System.find_executable("git")

  setup do
    repo = Path.join(System.tmp_dir!(), "gitf_resume_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf(repo) end)

    git = fn args, cd -> System.cmd(@git, args, cd: cd, stderr_to_stdout: true) end
    git.(["init", "-q", "-b", "main"], repo)
    git.(["config", "user.email", "t@t.dev"], repo)
    git.(["config", "user.name", "t"], repo)
    File.write!(Path.join(repo, "README.md"), "base\n")
    git.(["add", "-A"], repo)
    git.(["commit", "-qm", "base"], repo)

    {:ok, sector} = Archive.insert(:sectors, %{name: "resume-sector", path: repo})

    %{repo: repo, sector: sector, git: git}
  end

  # A mission that got as far as a real implementation worktree with a
  # commit in it — the shape every resumable failure has.
  defp mission_with_work(sector, repo, git, opts \\ []) do
    {:ok, mission} =
      Missions.create(%{goal: "Add the feature", sector_id: sector.id, status: "active"})

    ghost_id = "ghost-#{:erlang.unique_integer([:positive])}"
    branch = "ghost/#{ghost_id}"
    worktree = Path.join([repo, "ghosts", ghost_id])
    git.(["worktree", "add", "-q", worktree, "-b", branch], repo)
    File.write!(Path.join(worktree, "feature.ex"), "defmodule Feature do\nend\n")
    git.(["add", "-A"], worktree)
    git.(["commit", "-qm", "feature"], worktree)

    {:ok, op} =
      Ops.create(%{title: "Build feature", mission_id: mission.id, sector_id: sector.id})

    {:ok, ghost} =
      Archive.insert(:ghosts, %{id: ghost_id, name: "g", status: "stopped", op_id: op.id})

    {:ok, shell} =
      Archive.insert(:shells, %{
        sector_id: sector.id,
        ghost_id: ghost.id,
        worktree_path: worktree,
        branch: branch,
        status: "active",
        removed_at: nil
      })

    Archive.update(:ghosts, ghost.id, &Map.put(&1, :shell_id, shell.id))

    Archive.update(:ops, op.id, fn o ->
      Map.merge(o, %{
        status: "done",
        ghost_id: ghost.id,
        changed_files: Keyword.get(opts, :changed_files, ["feature.ex"]),
        files_changed: 1
      })
    end)

    Enum.each(Keyword.get(opts, :artifacts, %{}), fn {phase, artifact} ->
      Missions.store_artifact(mission.id, phase, artifact)
    end)

    if mode = Keyword.get(opts, :pipeline_mode) do
      Missions.update(mission.id, %{pipeline_mode: mode, pipeline_mode_forced: true})
    end

    %{mission_id: mission.id, branch: branch, worktree: worktree, op: op}
  end

  defp sha(repo, ref) do
    {out, 0} = System.cmd(@git, ["rev-parse", ref], cd: repo, stderr_to_stdout: true)
    String.trim(out)
  end

  describe "failure preserves the canonical branch" do
    test "fail_quest archives the canonical tree at the same commit", %{
      repo: repo,
      sector: sector,
      git: git
    } do
      %{mission_id: mid, branch: branch} = mission_with_work(sector, repo, git)
      tip = sha(repo, branch)

      {:ok, _} = Missions.fail_quest(mid, "validation never converged")

      archive = Topology.archive_branch(mid)
      assert Git.branch_exists?(repo, archive)
      assert sha(repo, archive) == tip
    end

    test "the archive branch outlives the worktree it was cut from", %{
      repo: repo,
      sector: sector,
      git: git
    } do
      %{mission_id: mid, branch: branch, worktree: wt} = mission_with_work(sector, repo, git)
      tip = sha(repo, branch)

      {:ok, _} = Missions.fail_quest(mid, "gone")

      # Exactly what the shell reaper does once the mission reads "failed".
      Git.worktree_remove(repo, wt, force: true)
      assert :ok = Git.branch_delete(repo, branch)
      refute Git.branch_exists?(repo, branch)

      assert sha(repo, Topology.archive_branch(mid)) == tip
    end

    test "kill archives before it deletes the mission", %{
      repo: repo,
      sector: sector,
      git: git
    } do
      %{mission_id: mid, branch: branch} = mission_with_work(sector, repo, git)
      tip = sha(repo, branch)

      :ok = Missions.kill(mid)

      assert Archive.get(:missions, mid) == nil
      assert sha(repo, Topology.archive_branch(mid)) == tip
    end

    test "prune paths refuse to delete archive branches", %{
      repo: repo,
      sector: sector,
      git: git
    } do
      %{mission_id: mid} = mission_with_work(sector, repo, git)
      {:ok, _} = Missions.fail_quest(mid, "gone")
      archive = Topology.archive_branch(mid)

      assert {:error, :archive_branch_protected} = Git.branch_delete(repo, archive)
      assert Git.branch_exists?(repo, archive)
    end

    test "a mission with no canonical branch fails without raising", %{sector: sector} do
      {:ok, mission} = Missions.create(%{goal: "nothing happened", sector_id: sector.id})

      assert {:ok, failed} = Missions.fail_quest(mission.id, "died in triage")
      assert failed.status == "failed"
    end

    test "a mission whose sector clone is gone still fails", %{} do
      {:ok, sector} =
        Archive.insert(:sectors, %{name: "vanished", path: "/tmp/gitf-no-such-repo"})

      {:ok, mission} = Missions.create(%{goal: "x", sector_id: sector.id})

      assert {:ok, failed} = Missions.fail_quest(mission.id, "died")
      assert failed.status == "failed"
    end
  end

  describe "resume/3 — error paths" do
    test "parent not found" do
      assert {:error, :parent_not_found} = Missions.resume("msn-nope")
    end

    test "parent is still running", %{repo: repo, sector: sector, git: git} do
      %{mission_id: mid} = mission_with_work(sector, repo, git)

      assert {:error, :parent_not_failed} = Missions.resume(mid)
    end

    test "unsupported from_phase", %{repo: repo, sector: sector, git: git} do
      %{mission_id: mid} = mission_with_work(sector, repo, git)
      {:ok, _} = Missions.fail_quest(mid, "gone")

      assert {:error, :unsupported_from_phase} = Missions.resume(mid, "design")
      assert {:error, :unsupported_from_phase} = Missions.resume(mid, "implementation")
    end

    test "no archive branch — a mission that failed before archival shipped", %{
      repo: repo,
      sector: sector,
      git: git
    } do
      %{mission_id: mid} = mission_with_work(sector, repo, git)
      {:ok, _} = Missions.fail_quest(mid, "gone")
      # Delete it the way only a pre-guard prune could have.
      System.cmd(@git, ["branch", "-D", Topology.archive_branch(mid)],
        cd: repo,
        stderr_to_stdout: true
      )

      assert {:error, :archive_branch_missing} = Missions.resume(mid)
    end

    test "sector clone is gone" do
      {:ok, sector} =
        Archive.insert(:sectors, %{name: "vanished", path: "/tmp/gitf-no-such-repo"})

      {:ok, mission} = Missions.create(%{goal: "x", sector_id: sector.id})
      {:ok, _} = Missions.fail_quest(mission.id, "died")

      assert {:error, :sector_unavailable} = Missions.resume(mission.id)
    end
  end

  describe "resume/3 — happy path" do
    setup %{repo: repo, sector: sector, git: git} do
      artifacts = %{
        "triage" => %{"complexity" => "moderate"},
        "research" => %{"summary" => "read the ground"},
        "requirements" => %{"reqs" => ["R1"]},
        "design_minimal" => %{"approach" => "small"},
        "design" => %{"approach" => "small"},
        "planning" => %{"ops" => ["one"]},
        # NOT inherited: validation is the resume point, and its verdict
        # belongs to the run that produced it.
        "validation" => %{"overall_verdict" => "fail"}
      }

      parent =
        mission_with_work(sector, repo, git,
          artifacts: artifacts,
          pipeline_mode: "full",
          changed_files: ["feature.ex", ".claude/settings.json"]
        )

      {:ok, _} = Missions.fail_quest(parent.mission_id, "validation never converged")

      # `advance: false`: the mission is built and inspected without handing
      # it to the orchestrator, which would spawn a real validation ghost.
      # The post-conditions asserted below ARE the orchestrator's entry
      # condition — see the "the journey can advance" test.
      {:ok, child} = Missions.resume(parent.mission_id, "validation", advance: false)

      %{parent: parent, child: child}
    end

    test "the child carries its provenance", %{parent: parent, child: child} do
      assert child.resumed_from == parent.mission_id
      assert child.resumed_at_phase == "validation"
      assert child.goal == "Add the feature"
      assert child.sector_id != nil
      assert String.ends_with?(child.name, "-resume")
    end

    test "the operator's forced pipeline mode survives the resume", %{child: child} do
      assert child.pipeline_mode == "full"
      assert child.pipeline_mode_forced == true
    end

    test "artifacts before the resume point are inherited and STAMPED", %{
      parent: parent,
      child: child
    } do
      for phase <- ~w(triage research requirements design planning) do
        artifact = Missions.get_artifact(child.id, phase)
        assert artifact, "expected #{phase} to be inherited"
        assert artifact["inherited_from"] == parent.mission_id
      end
    end

    test "parallel-phase artifact families come along", %{parent: parent, child: child} do
      assert Missions.get_artifact(child.id, "design_minimal")["inherited_from"] ==
               parent.mission_id
    end

    test "the resume point's own artifact is NOT inherited", %{child: child} do
      refute Missions.get_artifact(child.id, "validation")
    end

    test "inherited legs are recorded as replayed, not as real work", %{
      parent: parent,
      child: child
    } do
      transitions = Missions.get_phase_transitions(child.id)
      by_phase = Map.new(transitions, &{&1.to_phase, &1.reason})

      for phase <- ~w(triage research requirements design planning) do
        assert by_phase[phase] == "inherited from #{parent.mission_id}",
               "expected #{phase} to be marked replayed"
      end

      # The one leg this run really executes is reasoned differently.
      assert by_phase["implementation"] =~ "resumed from #{parent.mission_id}"
    end

    test "phases the parent never reached are not replayed", %{child: child} do
      phases = child.id |> Missions.get_phase_transitions() |> Enum.map(& &1.to_phase)
      refute "review" in phases
    end

    test "the synthetic op stands in for the inherited implementation", %{
      parent: parent,
      child: child
    } do
      [op] = Ops.list(mission_id: child.id)

      assert op.status == "done"
      assert op[:phase_job] == false
      assert op[:inherited] == true
      assert op.title == "Inherited implementation from #{parent.mission_id}"
    end

    test "the synthetic op carries the parent's changed files", %{child: child} do
      [op] = Ops.list(mission_id: child.id)

      # Without these, `validate_pass_against_diff/1` overrides every "pass"
      # verdict — the synthetic op is the resumed mission's ONLY impl op, so
      # an empty diff makes the run unpassable.
      assert "feature.ex" in op[:changed_files]
      assert op[:files_changed] == 2
    end

    test "the seeded worktree is checked out at the PARENT's final tree", %{
      repo: repo,
      parent: parent,
      child: child
    } do
      [op] = Ops.list(mission_id: child.id)
      ghost = Archive.get(:ghosts, op.ghost_id)
      shell = Archive.get(:shells, ghost.shell_id)

      assert File.dir?(shell.worktree_path)
      # The file the parent committed exists here; it does not exist on main.
      assert File.exists?(Path.join(shell.worktree_path, "feature.ex"))
      refute File.exists?(Path.join(repo, "feature.ex"))

      assert sha(shell.worktree_path, "HEAD") ==
               sha(repo, Topology.archive_branch(parent.mission_id))
    end

    test "canonical_impl_shell resolves to the inherited worktree", %{child: child} do
      {:ok, mission} = Missions.get(child.id)
      shell = GiTF.Validation.canonical_impl_shell(mission)

      assert shell
      assert File.exists?(Path.join(shell.worktree_path, "feature.ex"))
      assert GiTF.Validation.canonical_branch(mission) == shell.branch
    end

    test "the op, ghost and shell are wired to each other", %{child: child} do
      [op] = Ops.list(mission_id: child.id)
      ghost = Archive.get(:ghosts, op.ghost_id)
      shell = Archive.get(:shells, ghost.shell_id)

      assert ghost.op_id == op.id
      assert ghost.shell_id == shell.id
      assert ghost.shell_path == shell.worktree_path
      assert shell.ghost_id == ghost.id
      assert op[:shell_id] == shell.id
      assert op[:branch] == shell.branch
    end

    test "the journey can advance: the mission sits at implementation with every op done", %{
      child: child
    } do
      {:ok, mission} = Missions.get(child.id)

      # This IS `check_implementation_complete/1`'s entry condition — with
      # it satisfied, the orchestrator walks straight into start_validation.
      assert mission.status == "active"
      assert mission.current_phase == "implementation"

      impl_ops = Enum.reject(mission.ops, & &1[:phase_job])
      assert impl_ops != []
      assert Enum.all?(impl_ops, &(&1.status == "done"))
    end

    test "the parent is untouched", %{parent: parent} do
      {:ok, reloaded} = Missions.get(parent.mission_id)
      assert reloaded.status == "failed"
      refute reloaded[:resumed_from]
    end
  end

  # msn-978954: the parent judged FR-5 unmet, the resumed child's
  # validator judged the identical code met — because the child's record
  # started with both requirement registers empty and had no way to know
  # the argument had already been had.
  describe "resume/3 — the requirement registers cross the boundary" do
    setup %{repo: repo, sector: sector, git: git} do
      artifacts = %{
        "requirements" => %{"reqs" => ["FR-1", "FR-5"]},
        "validation" => %{
          "overall_verdict" => "fail",
          "requirements_met" => [
            %{"req_id" => "FR-1", "met" => true},
            %{"req_id" => "FR-5", "met" => false, "evidence" => "no retry on 5xx responses"}
          ]
        }
      }

      parent = mission_with_work(sector, repo, git, artifacts: artifacts)

      # The ratchet had banked BOTH — including the one the same round
      # rejected, which is the state a mid-flight fix round leaves behind.
      Missions.update(parent.mission_id, %{accepted_requirements: ["FR-1", "FR-5"]})
      {:ok, _} = Missions.fail_quest(parent.mission_id, "validation never converged")

      {:ok, child} = Missions.resume(parent.mission_id, "validation", advance: false)

      %{parent: parent, child: child}
    end

    test "the parent's UNMET verdict arrives contested, with its reason", %{child: child} do
      assert child[:contested_requirements] == [
               %{"req_id" => "FR-5", "reason" => "no retry on 5xx responses"}
             ]
    end

    test "the accepted set loses whatever is still contested", %{child: child} do
      # An id on both registers is a contradiction, and only the
      # fail-closed reading is safe: inheriting FR-5 as accepted would
      # pin it in the child's prompt as SETTLED — the ratchet doing the
      # false pass' work for it.
      assert child[:accepted_requirements] == ["FR-1"]
    end

    test "the parent's registers are not disturbed", %{parent: parent} do
      {:ok, reloaded} = Missions.get(parent.mission_id)
      assert reloaded[:accepted_requirements] == ["FR-1", "FR-5"]
    end
  end

  describe "resume/3 — probe residue committed by an earlier run" do
    test "a tree seeded with committed probe screenshots arrives without them", %{
      repo: repo,
      sector: sector,
      git: git
    } do
      parent = mission_with_work(sector, repo, git)

      # The state every pre-guard run left behind: the probe's PNGs are
      # in HEAD. Nothing downstream removes tracked files, so without the
      # seed-time scrub they ride into the resumed run's every diff and
      # out through its PR.
      File.mkdir_p!(Path.join(parent.worktree, ".gitf-probe"))
      File.write!(Path.join([parent.worktree, ".gitf-probe", "boot.png"]), "PNG")
      git.(["add", "-Af"], parent.worktree)
      git.(["commit", "-qm", "probe residue"], parent.worktree)

      {:ok, _} = Missions.fail_quest(parent.mission_id, "died")
      {:ok, child} = Missions.resume(parent.mission_id, "validation", advance: false)

      [op] = Ops.list(mission_id: child.id)
      ghost = Archive.get(:ghosts, op.ghost_id)
      shell = Archive.get(:shells, ghost.shell_id)

      {tracked, 0} = System.cmd(@git, ["ls-files"], cd: shell.worktree_path)
      refute tracked =~ ".gitf-probe"
      refute File.exists?(Path.join([shell.worktree_path, ".gitf-probe", "boot.png"]))

      # The inherited WORK is still there — the scrub removes residue, not
      # the tree it is sitting in.
      assert File.exists?(Path.join(shell.worktree_path, "feature.ex"))
    end
  end

  # A parent has exactly ONE resumable tree, so it may have at most one
  # live child. Two MCP calls that timed out client-side (while succeeding
  # server-side) produced FOUR missions racing for the same archive branch.
  describe "resume/3 — one live resume per parent" do
    setup %{repo: repo, sector: sector, git: git} do
      parent = mission_with_work(sector, repo, git)
      {:ok, _} = Missions.fail_quest(parent.mission_id, "died")
      {:ok, first} = Missions.resume(parent.mission_id, "validation", advance: false)

      %{parent: parent, first: first}
    end

    test "a second resume returns the FIRST child and creates nothing", %{
      parent: parent,
      first: first
    } do
      assert {:ok, again} = Missions.resume(parent.mission_id, "validation", advance: false)
      assert again.id == first.id

      children = Archive.filter(:missions, &(&1[:resumed_from] == parent.mission_id))
      assert length(children) == 1
    end

    test "the repeat is reported as :already_resumed, not as a new mission", %{
      parent: parent,
      first: first
    } do
      assert {:ok, mission, :already_resumed} =
               Missions.resume_with_status(parent.mission_id, "validation", advance: false)

      assert mission.id == first.id
    end

    test "the FIRST call is reported as :created", %{repo: repo, sector: sector, git: git} do
      other = mission_with_work(sector, repo, git)
      {:ok, _} = Missions.fail_quest(other.mission_id, "died")

      assert {:ok, _mission, :created} =
               Missions.resume_with_status(other.mission_id, "validation", advance: false)
    end

    test "a SPENT child releases the parent for another resume", %{
      parent: parent,
      first: first
    } do
      # The guard is about live work, not about history: a failed resume
      # must not lock the parent out forever.
      {:ok, _} = Missions.fail_quest(first.id, "the resume failed too")

      assert {:ok, second, :created} =
               Missions.resume_with_status(parent.mission_id, "validation", advance: false)

      refute second.id == first.id
    end

    test "live_resume_of/1 names the child, or nothing", %{parent: parent, first: first} do
      assert Missions.live_resume_of(parent.mission_id)[:id] == first.id
      assert Missions.live_resume_of("msn-unrelated") == nil
    end
  end

  # The synchronous seed took >60s under load, the MCP client timed out,
  # and the operator retried a call that had in fact succeeded.
  describe "resume/3 — async seeding" do
    setup %{repo: repo, sector: sector, git: git} do
      parent = mission_with_work(sector, repo, git)
      {:ok, _} = Missions.fail_quest(parent.mission_id, "died")

      %{parent: parent}
    end

    test "returns before the worktree exists, parked at pending", %{parent: parent} do
      assert {:ok, child, :created} =
               Missions.resume_with_status(parent.mission_id, "validation",
                 async: true,
                 advance: false
               )

      assert child.resumed_from == parent.mission_id
      # "pending", not "active": nothing may advance a mission whose tree
      # has not been cut yet.
      assert child.status == "pending"
      assert child[:resume_seeding] == true
    end

    test "the seeding task finishes the job", %{parent: parent} do
      {:ok, child, :created} =
        Missions.resume_with_status(parent.mission_id, "validation",
          async: true,
          advance: false
        )

      assert eventually(fn ->
               {:ok, m} = Missions.get(child.id)
               m.status == "active" and m.current_phase == "implementation"
             end)

      {:ok, seeded} = Missions.get(child.id)
      refute seeded[:resume_seeding]

      [op] = Ops.list(mission_id: child.id)
      ghost = Archive.get(:ghosts, op.ghost_id)
      shell = Archive.get(:shells, ghost.shell_id)
      assert File.exists?(Path.join(shell.worktree_path, "feature.ex"))
    end

    test "a seeding failure FAILS the mission with a reason — never a pending zombie", %{
      repo: repo,
      sector: sector,
      git: git
    } do
      parent = mission_with_work(sector, repo, git)
      {:ok, _} = Missions.fail_quest(parent.mission_id, "died")

      # Every check `resume/3` performs up front still passes — the clone
      # is there and the archive branch survived — but `git worktree add`
      # cannot put anything under `<repo>/ghosts` when that name is a
      # FILE. That is the shape of the failure this guard exists for: the
      # tree cannot be provisioned AFTER the mission record is live.
      Git.worktree_remove(repo, Path.join([repo, "ghosts", "x"]), force: true)
      File.rm_rf!(Path.join(repo, "ghosts"))
      File.write!(Path.join(repo, "ghosts"), "not a directory")

      {:ok, child, :created} =
        Missions.resume_with_status(parent.mission_id, "validation",
          async: true,
          advance: false
        )

      assert eventually(fn ->
               {:ok, m} = Missions.get(child.id)
               m.status == "failed"
             end),
             "a resume that cannot provision its tree must FAIL, not sit at pending"

      {:ok, settled} = Missions.get(child.id)
      assert settled[:failure_reason] =~ "worktree"

      refute settled[:resume_seeding],
             "the seeding flag must be cleared whichever way the task ended"
    end

    test "the async path is still guarded by the one-live-resume rule", %{parent: parent} do
      {:ok, first, :created} =
        Missions.resume_with_status(parent.mission_id, "validation",
          async: true,
          advance: false
        )

      assert {:ok, again, :already_resumed} =
               Missions.resume_with_status(parent.mission_id, "validation",
                 async: true,
                 advance: false
               )

      assert again.id == first.id
    end
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts <= 0 -> false
      true -> Process.sleep(50) && eventually(fun, attempts - 1)
    end
  end
end
