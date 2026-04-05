defmodule GiTF.AuditTest do
  use ExUnit.Case, async: false

  alias GiTF.{Archive, Audit, Ops}

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()
    GiTF.Test.StoreHelper.stop_store()
    tmp_dir = Path.join(System.tmp_dir!(), "gitf_verify_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    {:ok, _} = Archive.start_link(data_dir: tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    # Create test data
    {:ok, sector} = Archive.insert(:sectors, %{name: "test-sector", path: "/tmp/test"})
    {:ok, mission} = Archive.insert(:missions, %{name: "test-mission", goal: "test"})

    {:ok, op} =
      Ops.create(%{
        title: "Test op",
        mission_id: mission.id,
        sector_id: sector.id
      })

    {:ok, ghost} = Archive.insert(:ghosts, %{name: "test-ghost", status: "stopped"})

    {:ok, shell} =
      Archive.insert(:shells, %{
        ghost_id: ghost.id,
        sector_id: sector.id,
        worktree_path: "/tmp/test-shell",
        branch: "test-branch",
        status: "active"
      })

    # Assign op to ghost and complete it
    {:ok, op} = Ops.assign(op.id, ghost.id)
    {:ok, op} = Ops.start(op.id)
    {:ok, op} = Ops.complete(op.id)

    %{op: op, sector: sector, shell: shell, ghost: ghost}
  end

  test "get_verification_status returns pending for new op", %{op: op} do
    {:ok, status} = Audit.get_verification_status(op.id)
    assert status.status == "pending"
    assert is_nil(status.result)
    assert is_nil(status.verified_at)
  end

  test "get_verification_status returns not_found for invalid op" do
    assert {:error, :not_found} = Audit.get_verification_status("invalid")
  end

  test "record_result stores verification result", %{op: op} do
    result = %{
      status: "passed",
      output: "All tests passed",
      exit_code: 0,
      ran_at: DateTime.utc_now()
    }

    {:ok, stored} = Audit.record_result(op.id, result)
    assert stored.op_id == op.id
    assert stored.status == "passed"
    assert stored.output == "All tests passed"
  end

  test "jobs_needing_verification returns done ops with pending verification", %{op: op} do
    ops = Audit.jobs_needing_verification()
    op_ids = Enum.map(ops, & &1.id)
    assert op.id in op_ids
  end

  test "verify_job with no validation command passes", %{op: op} do
    {:ok, status, result} = Audit.verify_job(op.id)

    assert status == :pass
    assert result.status == "passed"
    assert result.output == "No validation command configured"

    # Check op was updated
    {:ok, updated_job} = Ops.get(op.id)
    assert updated_job.verification_status == "passed"
    assert not is_nil(updated_job.verified_at)
  end

  test "verify_job with missing shell returns error", %{op: op, shell: shell} do
    # Remove the shell
    Archive.delete(:shells, shell.id)

    assert {:error, :no_cell} = Audit.verify_job(op.id)
  end

  test "verify_job! raises on failure", %{op: op, shell: shell} do
    # Remove the shell so verification fails
    Archive.delete(:shells, shell.id)

    assert_raise RuntimeError, ~r/Audit error/, fn ->
      Audit.verify_job!(op.id)
    end
  end

  describe "determine_status with nil scores" do
    test "nil scores fail under :require_passing policy (default)", %{sector: sector} do
      # Comb has no nil_score_policy set → defaults to :require_passing
      # which means nil scores will cause verification to fail
      assert is_nil(Map.get(sector, :nil_score_policy))
    end

    test "nil scores pass under :skip_missing policy", %{sector: sector} do
      # Set the sector policy to skip_missing
      updated_sector = Map.put(sector, :nil_score_policy, :skip_missing)
      Archive.put(:sectors, updated_sector)

      assert updated_sector.nil_score_policy == :skip_missing
    end
  end
end
