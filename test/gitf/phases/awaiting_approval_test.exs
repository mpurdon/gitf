defmodule GiTF.Phases.AwaitingApprovalTest do
  use GiTF.StoreCase

  alias GiTF.Phases.AwaitingApproval

  defp insert_mission!(attrs) do
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

  describe "verdict/2 — timeout with re-validation disagreement" do
    # A pending request old enough that timed_out?/1 is true (test env has
    # no sleep intervals and no boot-grace marker).
    defp insert_pending_request!(mission_id, attrs) do
      {:ok, r} =
        GiTF.Archive.insert(
          :approval_requests,
          Map.merge(
            %{
              mission_id: mission_id,
              status: "pending",
              requested_at: DateTime.add(DateTime.utc_now(), -3 * 3600, :second)
            },
            attrs
          )
        )

      r
    end

    test "re-validation failure holds for the human instead of rejecting (msn-aa92dd)" do
      # One "done" impl op whose Audit.verify_job/1 cannot pass — the same
      # shape as a security-scan flap during auto-approve re-validation.
      m = insert_mission!(%{ops: [%{id: "op-nonexistent", status: "done"}]})
      req = insert_pending_request!(m.id, %{})

      assert AwaitingApproval.verdict(m, nil) == :wait

      # The disagreement was recorded on the request, the approval is still
      # pending, and the mission was NOT failed.
      reloaded_req = GiTF.Archive.get(:approval_requests, req.id)
      assert reloaded_req.revalidation_disagreement == true
      assert reloaded_req.status == "pending"
      assert GiTF.Archive.get(:missions, m.id).status == "active"
    end

    test "a recorded disagreement short-circuits to :wait without re-running revalidation" do
      m = insert_mission!(%{ops: [%{id: "op-nonexistent", status: "done"}]})
      insert_pending_request!(m.id, %{revalidation_disagreement: true})

      assert AwaitingApproval.verdict(m, nil) == :wait
      assert GiTF.Archive.get(:missions, m.id).status == "active"
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
