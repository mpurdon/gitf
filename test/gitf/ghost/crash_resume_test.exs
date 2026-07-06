defmodule GiTF.Ghost.CrashResumeTest do
  @moduledoc """
  Exercises the checkpoint/resume subsystem the audit flagged as untested:
  a ghost that crashes mid-op checkpoints its state, and a restart resumes from
  that checkpoint instead of starting from scratch.
  """
  use GiTF.StoreCase

  alias GiTF.{Archive, Backup}
  require GiTF.Ghost.Status
  alias GiTF.Ghost.Status, as: GhostStatus

  describe "Backup checkpoint round-trip" do
    test "save then load preserves the checkpoint fields" do
      ghost_id = "ghost-#{:erlang.unique_integer([:positive])}"

      {:ok, _} =
        Backup.save(ghost_id, %{
          progress_summary: "wrote the parser",
          files_modified: ["lib/parser.ex"],
          pending_work: "add tests",
          iteration: 4,
          phase: "implementation"
        })

      assert {:ok, backup} = Backup.load(ghost_id)
      assert backup.progress_summary == "wrote the parser"
      assert backup.files_modified == ["lib/parser.ex"]
      assert backup.pending_work == "add tests"
      assert backup.iteration == 4
    end

    test "load returns not_found for a ghost with no checkpoint" do
      assert {:error, :not_found} = Backup.load("ghost-never-saved")
    end

    test "the most recent checkpoint wins" do
      ghost_id = "ghost-#{:erlang.unique_integer([:positive])}"
      {:ok, _} = Backup.save(ghost_id, %{progress_summary: "v1", iteration: 1})
      {:ok, _} = Backup.save(ghost_id, %{progress_summary: "v2", iteration: 2})

      assert {:ok, %{iteration: 2, progress_summary: "v2"}} = Backup.load(ghost_id)
    end
  end

  describe "resume prompt" do
    test "carries the checkpoint context forward so work isn't redone" do
      {:ok, backup} =
        (fn ->
           ghost_id = "ghost-#{:erlang.unique_integer([:positive])}"

           Backup.save(ghost_id, %{
             progress_summary: "migrated the schema",
             files_modified: ["priv/repo/migrations/1.exs"],
             pending_work: "backfill the data",
             phase: "implementation"
           })

           Backup.load(ghost_id)
         end).()

      prompt = Backup.build_resume_prompt(backup)

      assert prompt =~ "Resuming Previous Work"
      assert prompt =~ "migrated the schema"
      assert prompt =~ "priv/repo/migrations/1.exs"
      assert prompt =~ "backfill the data"
    end
  end

  describe "restart detection" do
    test "a ghost marked restarting is recognized as resumable, not fresh" do
      {:ok, ghost} =
        Archive.insert(:ghosts, %{name: "resumable", status: GhostStatus.working()})

      {:ok, _} = Backup.save(ghost.id, %{progress_summary: "half done", iteration: 3})

      # Simulate the crash side of the contract: terminate/2 flips status to
      # restarting and leaves a checkpoint behind.
      {:ok, _} =
        Archive.update(:ghosts, ghost.id, fn g -> %{g | status: GhostStatus.restarting()} end)

      reloaded = Archive.get(:ghosts, ghost.id)
      assert reloaded.status == GhostStatus.restarting()
      # The checkpoint the resume path will consume is present.
      assert {:ok, %{iteration: 3}} = Backup.load(ghost.id)
    end
  end
end
