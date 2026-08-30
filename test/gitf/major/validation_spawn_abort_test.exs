defmodule GiTF.Major.ValidationSpawnAbortTest do
  @moduledoc """
  msn-05bebd: `do_start_validation/3` transitions the mission to
  `validation` and only THEN gathers the prompt's inputs — LSP
  diagnostics, the ground-truth exec validation, the main-advance
  summary. The exec validation is the only one of those that shells out,
  and when it failed it did not return an error: it took the calling
  process down with it, leaving the mission at `phase = validation` with
  no validation op in existence and a verdict handler that answered
  "wait" forever.

  The mechanism is an EXIT, not an exception, which is why the `rescue`
  clauses in `GroundTruth.run_exec_validation/2` and
  `Validator.run_validation/4` both miss it: the command runner spawns a
  LINKED `Task`, and `System.cmd/3` raises `:enoent` inside it when the
  executable it was handed does not exist (a missing sandbox binary is
  the live case — `GiTF.Git.safe_cmd/2` carries a comment about being
  bitten by exactly this with a blind `/usr/bin/git` fallback).

  Test one reproduces that mechanism. Test two pins the fix.
  """
  use GiTF.StoreCase

  alias GiTF.{Archive, Ops}
  alias GiTF.Major.{GroundTruth, PhaseLauncher}

  # Absolute path, with a fallback: `PATH` is a process-global in the
  # BEAM, and `runtime/{claude,kimi,copilot}_test` each set it to "/empty"
  # for the duration of a test.
  @git System.find_executable("git") || "/usr/bin/git"

  # A sandbox adapter that hands `System.cmd/3` an executable which is not
  # there. `available?/0` must be true and `name/0` must not be "local",
  # or `Sandbox.effective?/0` short-circuits to the plain `sh` path.
  defmodule VanishedSandbox do
    @behaviour GiTF.Sandbox

    @impl true
    def wrap_command(_cmd, args, _opts), do: {"/nonexistent/gitf-vanished-sandbox", args, []}

    @impl true
    def available?, do: true

    @impl true
    def name, do: "vanished"
  end

  setup do
    repo = Path.join(System.tmp_dir!(), "gitf_spawnabort_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf(repo) end)

    git = fn args, cd -> System.cmd(@git, args, cd: cd, stderr_to_stdout: true) end
    git.(["init", "-q", "-b", "main"], repo)
    git.(["config", "user.email", "t@t.dev"], repo)
    git.(["config", "user.name", "t"], repo)
    File.write!(Path.join(repo, "README.md"), "base\n")
    git.(["add", "-A"], repo)
    git.(["commit", "-qm", "base"], repo)

    {:ok, sector} =
      Archive.insert(:sectors, %{
        name: "abort-sector",
        path: repo,
        validation_command: "gitf-no-such-build-tool --check"
      })

    {:ok, mission} =
      Archive.insert(:missions, %{
        name: "abort",
        goal: "ship it",
        status: "active",
        sector_id: sector.id,
        current_phase: "validation",
        artifacts: %{},
        ops: []
      })

    # An impl op → ghost → shell chain, because that is what
    # `Topology.exec_validation_shell/2` walks to find a worktree to run in.
    ghost_id = "ghost-#{:erlang.unique_integer([:positive])}"
    worktree = Path.join([repo, "ghosts", ghost_id])
    git.(["worktree", "add", "-q", worktree, "-b", "ghost/#{ghost_id}"], repo)

    {:ok, op} = Ops.create(%{title: "Build it", mission_id: mission.id, sector_id: sector.id})

    {:ok, ghost} =
      Archive.insert(:ghosts, %{id: ghost_id, name: "g", status: "stopped", op_id: op.id})

    {:ok, shell} =
      Archive.insert(:shells, %{
        sector_id: sector.id,
        ghost_id: ghost.id,
        worktree_path: worktree,
        branch: "ghost/#{ghost_id}",
        status: "active",
        removed_at: nil
      })

    Archive.update(:ghosts, ghost.id, &Map.put(&1, :shell_id, shell.id))

    Archive.update(:ops, op.id, fn o ->
      Map.merge(o, %{status: "done", ghost_id: ghost.id, changed_files: ["README.md"]})
    end)

    {:ok, mission} = GiTF.Missions.get(mission.id)

    %{repo: repo, sector: sector, mission: mission}
  end

  defp with_vanished_sandbox(fun) do
    previous = Application.get_env(:gitf, :sandbox_adapter)
    Application.put_env(:gitf, :sandbox_adapter, VanishedSandbox)

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:gitf, :sandbox_adapter, previous),
        else: Application.delete_env(:gitf, :sandbox_adapter)
    end
  end

  describe "the mechanism" do
    test "run_exec_validation kills its caller when the runner cannot spawn", %{mission: mission} do
      with_vanished_sandbox(fn ->
        {pid, ref} =
          spawn_monitor(fn ->
            # The `rescue` inside run_exec_validation cannot see this: the
            # raise happens in a linked Task, so it arrives here as a
            # signal, not as an exception.
            GroundTruth.run_exec_validation(mission, nil)
          end)

        assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 20_000
        refute reason == :normal, "expected the caller to be killed by the runner's exit"

        # Named precisely, because the whole point is that this is NOT an
        # exception any `rescue` in the chain could have caught.
        assert match?({:enoent, _}, reason), "expected an :enoent exit, got: #{inspect(reason)}"
      end)
    end
  end

  describe "the fix: nothing gathered for the prompt may abort the spawn" do
    test "an unspawnable runner comes back as a value, not as a caller death", %{
      mission: mission
    } do
      with_vanished_sandbox(fn ->
        {verdict, notes} = PhaseLauncher.exec_validation_or_note(mission, nil)

        assert verdict == nil, "no ground truth was obtained, so none may be claimed"
        assert [note] = notes
        assert note =~ "UNAVAILABLE"
      end)
    end

    test "the aborted round still records an INFRA verdict, so no fix attempt is burned", %{
      mission: mission
    } do
      with_vanished_sandbox(fn ->
        PhaseLauncher.exec_validation_or_note(mission, nil)
      end)

      verdict = GiTF.Missions.get_artifact(mission.id, "exec_validation")

      assert verdict["status"] == "fail"
      assert verdict["infra_failure"] == true
      # Nothing was measured, so nothing may be cached against a tree.
      assert verdict["tree"] == nil

      {:ok, reloaded} = GiTF.Missions.get(mission.id)
      assert GiTF.Phases.Validation.exec_infra_failure?(reloaded)
    end

    test "an exit-127 validation command spawns the validation ghost anyway", %{
      mission: mission
    } do
      # The ordinary infra failure: the command runs, the shell cannot find
      # the tool, exit 127. This one never crashed the caller — but the
      # claim being pinned is that the mission always ends up with a
      # validation op, whatever ground truth reports.
      assert {:ok, "validation"} = PhaseLauncher.start_validation(mission)

      validation_ops =
        Ops.list(mission_id: mission.id)
        |> Enum.filter(&(&1[:phase] == "validation"))

      assert validation_ops != [], "the validation ghost's op must exist"

      verdict = GiTF.Missions.get_artifact(mission.id, "exec_validation")
      assert verdict["status"] == "fail"
      assert verdict["infra_failure"] == true
      assert verdict["kind"] == "tool_missing"
    end

    test "the ghost's prompt carries the failed ground truth", %{mission: mission} do
      assert {:ok, "validation"} = PhaseLauncher.start_validation(mission)

      [op] =
        Ops.list(mission_id: mission.id)
        |> Enum.filter(&(&1[:phase] == "validation"))

      assert op.description =~ "Execution validation: FAILED"
    end

    # The ratchet's other half: `Phases.Validation` records the accepted
    # ids, and the NEXT round's prompt has to actually carry them or the
    # fix budget goes on re-litigation again.
    test "the ghost's prompt carries the requirements an earlier round accepted", %{
      mission: mission
    } do
      Archive.update(:missions, mission.id, fn m ->
        Map.put(m, :accepted_requirements, ["FR-1", "FR-2"])
      end)

      {:ok, mission} = GiTF.Missions.get(mission.id)
      assert {:ok, "validation"} = PhaseLauncher.start_validation(mission)

      [op] =
        Ops.list(mission_id: mission.id)
        |> Enum.filter(&(&1[:phase] == "validation"))

      assert op.description =~ "ALREADY ACCEPTED"
      assert op.description =~ "FR-1, FR-2"
    end
  end
end
