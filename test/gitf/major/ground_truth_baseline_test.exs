defmodule GiTF.Major.GroundTruthBaselineTest do
  @moduledoc """
  A validation failure that is ALSO on the base commit is the sector's
  problem, not the mission's. msn-f24c5f: cora's main had reqwest under a
  macOS-only dependency table; a CSS-only mission "failed" its build and
  three fix ghosts rewrote Cargo.toml chasing it.
  """
  use GiTF.StoreCase

  alias GiTF.Archive
  alias GiTF.Major.GroundTruth

  # A repo whose validation command is `sh check.sh`; main's check.sh
  # exits with `base_exit`, and a branch adds one commit on top.
  defp repo!(base_exit) do
    dir = Path.join(System.tmp_dir!(), "gitf_baseline_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    git = fn args -> {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true) end
    git.(["init", "-q", "-b", "main"])
    git.(["config", "user.email", "t@t"])
    git.(["config", "user.name", "t"])
    File.write!(Path.join(dir, "check.sh"), "echo base-says-#{base_exit}; exit #{base_exit}\n")
    git.(["add", "."])
    git.(["commit", "-q", "-m", "base"])
    git.(["checkout", "-q", "-b", "ghost/x"])
    File.write!(Path.join(dir, "style.css"), "a{}\n")
    git.(["add", "."])
    git.(["commit", "-q", "-m", "work"])
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, sector} = Archive.put(:sectors, %{id: "sec-bl-#{base_exit}", name: "bl", path: dir})
    {dir, sector}
  end

  test "a command that fails on the base commit is pre-existing, and the answer is cached" do
    {dir, sector} = repo!(1)

    assert {:fail, out} = GroundTruth.baseline_verdict(sector, dir, "main", "sh check.sh", 30_000)
    assert out =~ "base-says-1"

    # Cached per base commit + command: a second ask never builds again.
    File.write!(Path.join(dir, "check.sh"), "exit 0\n")
    assert {:fail, _} = GroundTruth.baseline_verdict(sector, dir, "main", "sh check.sh", 30_000)
    assert [_] = Archive.all(:validation_baselines)

    # The scratch worktree and its branch are gone.
    assert File.ls!(Path.join(dir, "ghosts")) == []
    {branches, 0} = System.cmd("git", ["branch", "--list", "gitf/baseline-*"], cd: dir)
    assert String.trim(branches) == ""
  end

  test "a command that passes on the base commit leaves the failure attributable" do
    {dir, sector} = repo!(0)
    assert {:pass, ""} = GroundTruth.baseline_verdict(sector, dir, "main", "sh check.sh", 30_000)
  end

  test "an unresolvable base is unknown, never a verdict" do
    {dir, sector} = repo!(0)
    assert :unknown = GroundTruth.baseline_verdict(sector, dir, "no-such-branch", "true", 30_000)
  end

  describe "what the pre-existing verdict tells the models" do
    test "the validation prompt names it and forbids marking requirements unmet for it" do
      mission = %{id: "msn-bl", goal: "G"}

      prompt =
        GiTF.Major.PhasePrompts.validation_prompt(
          mission,
          %{"functional_requirements" => []},
          [],
          "",
          exec_validation: {:pre_existing, "sh check.sh", "impl: E0433", "base: E0433"}
        )

      assert prompt =~ "ALSO FAILS ON THE BASE COMMIT (pre-existing)"
      assert prompt =~ "Do NOT mark any requirement unmet on account of this failure"
      assert prompt =~ "impl: E0433" and prompt =~ "base: E0433"
    end

    test "the exec verdict artifact reads back as pre-existing" do
      {:ok, m} = GiTF.Missions.create(%{goal: "bl"})
      refute GiTF.Phases.Validation.exec_pre_existing?(m)

      GiTF.Missions.store_artifact(m.id, "exec_validation", %{
        "status" => "fail",
        "pre_existing" => true,
        "output" => "x",
        "baseline_output" => "y"
      })

      assert GiTF.Phases.Validation.exec_pre_existing?(m)
      refute GiTF.Phases.Validation.exec_infra_failure?(GiTF.Archive.get(:missions, m.id))
    end
  end
end
