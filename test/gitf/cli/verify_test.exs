defmodule GiTF.CLI.VerifyTest do
  use ExUnit.Case, async: false

  @tmp_dir Path.join(System.tmp_dir!(), "gitf_verify_test")

  setup do
    store_dir = Path.join(@tmp_dir, "gitf_store_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(store_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Archive.start_link(data_dir: store_dir)

    on_exit(fn ->
      try do
        if Process.whereis(GiTF.Archive), do: GenServer.stop(GiTF.Archive)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(store_dir)
    end)

    :ok
  end

  describe "verification status tracking" do
    test "records verification results" do
      repo_path = Path.join(@tmp_dir, "test_repo_#{:erlang.unique_integer([:positive])}")
      GiTF.Test.StoreHelper.init_git_repo!(repo_path)
      System.cmd("git", ["init"], cd: repo_path)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: repo_path)
      System.cmd("git", ["config", "user.name", "Test"], cd: repo_path)

      {:ok, sector} = GiTF.Sector.add(repo_path, name: "test")

      {:ok, mission} =
        GiTF.Missions.create(%{name: "Test Quest", goal: "Test goal", sector_id: sector.id})

      {:ok, op} =
        GiTF.Ops.create(%{
          title: "Test Job",
          mission_id: mission.id,
          sector_id: sector.id,
          status: "done"
        })

      # Record a passing verification result
      result = %{status: "passed", validations: [], output: "All tests passed"}
      {:ok, _} = GiTF.Audit.record_result(op.id, result)

      # Check status was updated
      {:ok, updated_job} = GiTF.Ops.get(op.id)
      assert updated_job.verification_status == "passed"

      File.rm_rf!(repo_path)
    end

    test "tracks verification failures" do
      repo_path = Path.join(@tmp_dir, "test_repo_#{:erlang.unique_integer([:positive])}")
      GiTF.Test.StoreHelper.init_git_repo!(repo_path)
      System.cmd("git", ["init"], cd: repo_path)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: repo_path)
      System.cmd("git", ["config", "user.name", "Test"], cd: repo_path)

      {:ok, sector} = GiTF.Sector.add(repo_path, name: "test")

      {:ok, mission} =
        GiTF.Missions.create(%{name: "Test Quest", goal: "Test goal", sector_id: sector.id})

      {:ok, op} =
        GiTF.Ops.create(%{
          title: "Test Job",
          mission_id: mission.id,
          sector_id: sector.id,
          status: "done"
        })

      # Record a failing verification result
      result = %{
        status: "failed",
        validations: [%{name: "test", status: "fail", output: "Test failed"}],
        output: "Tests failed"
      }

      {:ok, _} = GiTF.Audit.record_result(op.id, result)

      {:ok, updated_job} = GiTF.Ops.get(op.id)
      assert updated_job.verification_status == "failed"

      File.rm_rf!(repo_path)
    end
  end
end
