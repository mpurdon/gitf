defmodule GiTF.OverrideTest do
  use ExUnit.Case, async: false

  alias GiTF.Override
  alias GiTF.Archive
  alias GiTF.Test.StoreHelper

  setup do
    data_dir = Path.join(System.tmp_dir!(), "gitf_test_gate_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(data_dir)
    StoreHelper.restart_store!(data_dir)

    on_exit(fn ->
      StoreHelper.stop_store()
      File.rm_rf!(data_dir)
    end)

    :ok
  end

  defp create_quest(opts \\ %{}) do
    goal = Map.get(opts, :goal, "Test mission")
    sector_id = Map.get(opts, :sector_id, "cmb_test")

    # Create sector
    comb_attrs = Map.get(opts, :sector, %{})
    sector = Map.merge(%{id: sector_id, path: "/tmp/test", name: "test"}, comb_attrs)
    Archive.insert(:sectors, sector)

    {:ok, mission} = GiTF.Missions.create(%{goal: goal, sector_id: sector_id})
    mission
  end

  defp add_job(mission, opts \\ %{}) do
    risk = Map.get(opts, :risk_level, :low)

    {:ok, op} = GiTF.Ops.create(%{
      title: "Test op",
      mission_id: mission.id,
      sector_id: mission.sector_id
    })

    # Set risk_level directly (classifier may override attrs)
    updated = %{op | risk_level: risk}
    Archive.put(:ops, updated)
    updated
  end

  describe "requires_approval?/1" do
    test "returns false when all ops are low risk" do
      mission = create_quest()
      add_job(mission, %{risk_level: :low})
      {:ok, mission} = GiTF.Missions.get(mission.id)

      refute Override.requires_approval?(mission)
    end

    test "returns true when a op has high risk" do
      mission = create_quest()
      add_job(mission, %{risk_level: :high})
      {:ok, mission} = GiTF.Missions.get(mission.id)

      assert Override.requires_approval?(mission)
    end

    test "returns true when a op has critical risk" do
      mission = create_quest()
      add_job(mission, %{risk_level: :critical})
      {:ok, mission} = GiTF.Missions.get(mission.id)

      assert Override.requires_approval?(mission)
    end

    test "returns true when sector has require_human_approval" do
      mission = create_quest(%{sector: %{require_human_approval: true}})
      add_job(mission, %{risk_level: :low})
      {:ok, mission} = GiTF.Missions.get(mission.id)

      assert Override.requires_approval?(mission)
    end

    test "returns false when no ops exist" do
      mission = create_quest()
      {:ok, mission} = GiTF.Missions.get(mission.id)

      refute Override.requires_approval?(mission)
    end
  end

  describe "approve/1 and reject/2" do
    test "approve stores artifact and updates status" do
      mission = create_quest()

      {:ok, artifact} = Override.approve(mission.id)
      assert artifact["approved"] == true

      assert Override.approval_status(mission.id) == :approved
    end

    test "reject stores artifact with reason" do
      mission = create_quest()

      {:ok, artifact} = Override.reject(mission.id, "Not ready")
      assert artifact["approved"] == false
      assert artifact["reason"] == "Not ready"

      assert Override.approval_status(mission.id) == :rejected
    end
  end

  describe "approval_status/1" do
    test "returns :not_required when no request exists" do
      mission = create_quest()
      assert Override.approval_status(mission.id) == :not_required
    end

    test "returns :pending after request_approval" do
      mission = create_quest()
      add_job(mission, %{risk_level: :high})
      {:ok, _request} = Override.request_approval(mission.id)

      assert Override.approval_status(mission.id) == :pending
    end

    test "returns :approved after approve" do
      mission = create_quest()
      {:ok, _request} = Override.request_approval(mission.id)
      {:ok, _} = Override.approve(mission.id)

      assert Override.approval_status(mission.id) == :approved
    end
  end

  describe "pending_approvals/0" do
    test "lists pending requests" do
      quest1 = create_quest(%{goal: "Quest 1"})
      quest2 = create_quest(%{goal: "Quest 2"})

      {:ok, _} = Override.request_approval(quest1.id)
      {:ok, _} = Override.request_approval(quest2.id)

      pending = Override.pending_approvals()
      assert length(pending) == 2

      # Approve one
      Override.approve(quest1.id)
      pending = Override.pending_approvals()
      assert length(pending) == 1
    end
  end

  describe "request_approval/1" do
    test "creates request with mission metadata" do
      mission = create_quest(%{goal: "Deploy new auth"})
      add_job(mission, %{risk_level: :high})

      {:ok, request} = Override.request_approval(mission.id)
      assert request.mission_id == mission.id
      assert request.goal == "Deploy new auth"
      assert request.status == "pending"
      assert :high in request.risk_levels
    end
  end
end
