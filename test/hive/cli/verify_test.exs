defmodule Hive.CLI.VerifyTest do
  use ExUnit.Case, async: false

  @tmp_dir Path.join(System.tmp_dir!(), "hive_verify_test")

  setup do
    store_dir = Path.join(@tmp_dir, "hive_store_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(store_dir)
    if Process.whereis(Hive.Store), do: GenServer.stop(Hive.Store)
    {:ok, _} = Hive.Store.start_link(data_dir: store_dir)

    on_exit(fn ->
      try do
        if Process.whereis(Hive.Store), do: GenServer.stop(Hive.Store)
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
      File.mkdir_p!(repo_path)
      System.cmd("git", ["init"], cd: repo_path)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: repo_path)
      System.cmd("git", ["config", "user.name", "Test"], cd: repo_path)

      {:ok, comb} = Hive.Comb.add(repo_path, name: "test")
      {:ok, quest} = Hive.Quests.create(%{name: "Test Quest", goal: "Test goal", comb_id: comb.id})
      {:ok, job} = Hive.Jobs.create(%{title: "Test Job", quest_id: quest.id, comb_id: comb.id, status: "done"})

      # Record a passing verification result
      result = %{status: "passed", validations: [], output: "All tests passed"}
      {:ok, _} = Hive.Verification.record_result(job.id, result)
      
      # Check status was updated
      {:ok, updated_job} = Hive.Jobs.get(job.id)
      assert updated_job.verification_status == "passed"

      File.rm_rf!(repo_path)
    end

    test "tracks verification failures" do
      repo_path = Path.join(@tmp_dir, "test_repo_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(repo_path)
      System.cmd("git", ["init"], cd: repo_path)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: repo_path)
      System.cmd("git", ["config", "user.name", "Test"], cd: repo_path)

      {:ok, comb} = Hive.Comb.add(repo_path, name: "test")
      {:ok, quest} = Hive.Quests.create(%{name: "Test Quest", goal: "Test goal", comb_id: comb.id})
      {:ok, job} = Hive.Jobs.create(%{title: "Test Job", quest_id: quest.id, comb_id: comb.id, status: "done"})

      # Record a failing verification result
      result = %{status: "failed", validations: [%{name: "test", status: "fail", output: "Test failed"}], output: "Tests failed"}
      {:ok, _} = Hive.Verification.record_result(job.id, result)
      
      {:ok, updated_job} = Hive.Jobs.get(job.id)
      assert updated_job.verification_status == "failed"

      File.rm_rf!(repo_path)
    end
  end
end
