defmodule Hive.VerificationTest do
  use ExUnit.Case, async: true

  alias Hive.{Store, Verification, Jobs}

  setup do
    # Start store for testing (handle already started)
    case Store.start_link(data_dir: System.tmp_dir!()) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
    
    # Create test data
    {:ok, comb} = Store.insert(:combs, %{name: "test-comb", path: "/tmp/test"})
    {:ok, quest} = Store.insert(:quests, %{name: "test-quest", goal: "test"})
    {:ok, job} = Jobs.create(%{
      title: "Test job",
      quest_id: quest.id,
      comb_id: comb.id
    })
    {:ok, bee} = Store.insert(:bees, %{name: "test-bee", status: "stopped"})
    {:ok, cell} = Store.insert(:cells, %{
      bee_id: bee.id,
      comb_id: comb.id,
      worktree_path: "/tmp/test-cell",
      branch: "test-branch",
      status: "active"
    })
    
    # Assign job to bee and complete it
    {:ok, job} = Jobs.assign(job.id, bee.id)
    {:ok, job} = Jobs.start(job.id)
    {:ok, job} = Jobs.complete(job.id)
    
    %{job: job, comb: comb, cell: cell, bee: bee}
  end

  test "get_verification_status returns pending for new job", %{job: job} do
    {:ok, status} = Verification.get_verification_status(job.id)
    assert status.status == "pending"
    assert is_nil(status.result)
    assert is_nil(status.verified_at)
  end

  test "get_verification_status returns not_found for invalid job" do
    assert {:error, :not_found} = Verification.get_verification_status("invalid")
  end

  test "record_result stores verification result", %{job: job} do
    result = %{
      status: "passed",
      output: "All tests passed",
      exit_code: 0,
      ran_at: DateTime.utc_now()
    }
    
    {:ok, stored} = Verification.record_result(job.id, result)
    assert stored.job_id == job.id
    assert stored.status == "passed"
    assert stored.output == "All tests passed"
  end

  test "jobs_needing_verification returns done jobs with pending verification", %{job: job} do
    jobs = Verification.jobs_needing_verification()
    job_ids = Enum.map(jobs, & &1.id)
    assert job.id in job_ids
  end

  test "verify_job with no validation command passes", %{job: job} do
    {:ok, status, result} = Verification.verify_job(job.id)
    
    assert status == :pass
    assert result.status == "passed"
    assert result.output == "No validation command configured"
    
    # Check job was updated
    {:ok, updated_job} = Jobs.get(job.id)
    assert updated_job.verification_status == "passed"
    assert not is_nil(updated_job.verified_at)
  end

  test "verify_job with missing cell returns error", %{job: job, cell: cell} do
    # Remove the cell
    Store.delete(:cells, cell.id)
    
    assert {:error, :no_cell} = Verification.verify_job(job.id)
  end
end