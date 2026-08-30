defmodule GiTF.Approval.GateStateTest do
  @moduledoc """
  msn-ac0539 sat blocked on a human for twelve hours while both pipeline
  widgets rendered it as **sync — actively merging**. The phase whose
  entire meaning is "the factory has stopped and a person is the blocker"
  had been removed from both display lists and aliased to the phase that
  means the opposite.

  `gate_state/1` is the single derivation both widgets now call, so they
  cannot disagree about the same mission. The rule that matters most is
  the conservative one: SKIPPED is claimed only once the gate is provably
  behind the mission. A gate that may still fire is never dimmed.
  """
  use GiTF.StoreCase

  alias GiTF.{Approval, Archive, Override}

  defp mission!(fields) do
    {:ok, m} =
      Archive.insert(
        :missions,
        Map.merge(
          %{
            name: "gate",
            goal: "x",
            status: "active",
            sector_id: "no-such-sector",
            artifacts: %{},
            ops: []
          },
          fields
        )
      )

    m
  end

  defp request!(mission_id) do
    {:ok, r} =
      Archive.insert(:approval_requests, %{
        mission_id: mission_id,
        quest_name: "gate",
        goal: "x",
        status: "pending",
        requested_at: DateTime.utc_now()
      })

    r
  end

  # gate_state reads the mission record fresh where it can; hand it the
  # stored copy so the artifact written by approve/reject is visible.
  defp reload(mission), do: Archive.get(:missions, mission.id)

  describe "held on the gate" do
    test "a mission at awaiting_approval is HELD" do
      m = mission!(%{current_phase: "awaiting_approval"})

      assert Approval.gate_state(m) == :held
    end

    test "held is answered without needing a request record" do
      # The phase itself is the fact. This must not depend on the store,
      # because being wrong here is what cost twelve hours.
      m = mission!(%{current_phase: "awaiting_approval"})

      assert Approval.gate_state(m) == :held
    end
  end

  describe "before the gate" do
    test "a mission still at validation reports the gate as FUTURE" do
      m = mission!(%{current_phase: "validation"})

      assert Approval.gate_state(m) == :future
    end

    test "every phase before the gate is future, never skipped" do
      for phase <-
            ~w(triage research requirements design review planning implementation validation) do
        m = mission!(%{current_phase: phase})

        assert Approval.gate_state(m) == :future,
               "#{phase} must not dim a gate that can still fire"
      end
    end
  end

  describe "past the gate" do
    test "nothing ever asked of a human is SKIPPED" do
      m = mission!(%{current_phase: "sync"})

      assert Override.approval_status(m.id) == :not_required
      assert Approval.gate_state(m) == :skipped
    end

    test "a mission that WAS approved is DECIDED, not skipped" do
      m = mission!(%{current_phase: "sync"})
      request!(m.id)
      {:ok, _} = Override.approve(m.id, %{approved_by: "matthew@purdonmoi.com"})

      assert Approval.gate_state(reload(m)) == :decided
    end

    test "an auto-timeout approval still counts as decided — it did happen" do
      m = mission!(%{current_phase: "sync"})
      request!(m.id)
      {:ok, _} = Override.approve(m.id, %{approved_by: "auto_timeout"})

      assert Approval.gate_state(reload(m)) == :decided
    end

    test "a rejected mission is decided" do
      m = mission!(%{current_phase: "sync"})
      request!(m.id)
      {:ok, _} = Override.reject(m.id, "not ready", %{rejected_by: "matthew@purdonmoi.com"})

      assert Approval.gate_state(reload(m)) == :decided
    end

    test "a request still open past the gate is an anomaly, reported as held" do
      m = mission!(%{current_phase: "sync"})
      request!(m.id)

      # Not skipped: a human is still nominally the blocker, and dimming
      # the step would hide the inconsistency.
      assert Approval.gate_state(m) == :held
    end

    test "later phases are all past the gate" do
      for phase <- ~w(sync simplify publish scoring) do
        m = mission!(%{current_phase: phase})

        assert Approval.gate_state(m) == :skipped, "#{phase} is past the gate"
      end
    end
  end

  describe "terminal missions" do
    test "a completed mission that never gated is skipped" do
      m = mission!(%{current_phase: "completed", status: "completed"})

      assert Approval.gate_state(m) == :skipped
    end

    test "a mission that died before reaching the gate is skipped, not future" do
      # It is not waiting for anything. A pending-looking step on a dead
      # mission is the same lie in a different colour.
      m = mission!(%{current_phase: "implementation", status: "failed"})

      assert Approval.gate_state(m) == :skipped
    end

    test "a killed mission that was approved still reads decided" do
      m = mission!(%{current_phase: "sync", status: "killed"})
      request!(m.id)
      {:ok, _} = Override.approve(m.id, %{approved_by: "matthew@purdonmoi.com"})

      assert Approval.gate_state(reload(m)) == :decided
    end
  end

  describe "degrades rather than raising" do
    test "a mission map with no id claims nothing" do
      assert Approval.gate_state(%{current_phase: "sync", status: "active"}) == :future
    end

    test "a non-map is future" do
      assert Approval.gate_state(nil) == :future
    end

    test "an unknown phase is treated as before the gate" do
      m = mission!(%{current_phase: "some_workflow_dsl_phase"})

      assert Approval.gate_state(m) == :future
    end
  end
end
