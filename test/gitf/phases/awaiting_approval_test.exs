defmodule GiTF.Phases.AwaitingApprovalTest do
  use GiTF.StoreCase

  alias GiTF.Phases.AwaitingApproval

  defp insert_mission!(attrs \\ %{}) do
    {:ok, m} =
      GiTF.Archive.insert(
        :missions,
        Map.merge(
          %{
            name: "a",
            goal: "x",
            status: "active",
            sector_id: "fe",
            current_phase: "awaiting_approval",
            artifacts: %{},
            ops: []
          },
          attrs
        )
      )

    m
  end

  describe "verdict/2 — operator-supplied approval" do
    test ":approved → :pass" do
      m = insert_mission!(%{artifacts: %{"approval" => %{"approved" => true}}})
      assert AwaitingApproval.verdict(m, nil) == :pass
    end

    test ":rejected → :terminal_fail" do
      m = insert_mission!(%{artifacts: %{"approval" => %{"approved" => false}}})
      assert AwaitingApproval.verdict(m, nil) == :terminal_fail
    end

    test ":not_required (no approval request and no artifact) → :pass" do
      m = insert_mission!(%{})
      # With no approval_requests row and no "approval" artifact,
      # Override.approval_status/1 returns :not_required.
      assert AwaitingApproval.verdict(m, nil) == :pass
    end
  end

  describe "terminal(:retries_exhausted)" do
    test "fails the mission" do
      m = insert_mission!(%{})
      AwaitingApproval.terminal(m, :retries_exhausted, nil)
      reloaded = GiTF.Archive.get(:missions, m.id)
      assert reloaded.status == "failed"
      assert reloaded.failure_reason =~ "Human review rejected"
    end
  end
end
