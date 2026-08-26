defmodule GiTF.Phases.AwaitingApproval do
  @moduledoc """
  Awaiting-approval phase handler.

  `start/3` delegates to `Orchestrator.dispatch_phase("awaiting_approval",
  mission)` → `GiTF.Approval.request/1` (transition +
  `Override.request_approval/1` + `:approval_requested` operator
  webhook).

  `verdict/2` mirrors `GiTF.Approval.handle_result/1` exactly,
  translated into workflow verdicts:

    * `:approved` → `:pass` (route to merge via `on_pass: sync`)
    * `:not_required` → `:pass`
    * `:rejected` → `:terminal_fail` (the terminal callback fails the
      mission with "Human review rejected")
    * `:pending` + no timeout → `:wait`
    * `:pending` + timeout:
      * critical-risk mission → dispatch `:approval_timeout_critical`
        alert and return `:wait` (never auto-approves critical work)
      * re-validation fresh → `Override.approve/2` with `auto_timeout`
        and return `:pass`
      * re-validation failed → record the disagreement on the request,
        alert the operator once, and return `:wait` (work that passed
        validation is never auto-rejected on a machine disagreement)

  Side effects (auto-approve, reject, alert) happen inside the verdict
  function to match the legacy code's structure. This is consistent with
  how `Phases.Validation` will handle cross-check artifact overrides.

  Pair with a workflow phase config like:

      - id: awaiting_approval
        handler: GiTF.Phases.AwaitingApproval
        on_pass: sync
        on_fail: awaiting_approval
        max_retries: 0
        on_exhausted: fail
  """

  @behaviour GiTF.Phase

  require Logger

  alias GiTF.Approval
  alias GiTF.Major.Orchestrator

  @impl true
  def start(mission, %GiTF.Workflow.Phase{id: id}, _ctx) do
    Orchestrator.dispatch_phase(id, mission)
  end

  @impl true
  def verdict(mission, _artifact) do
    case GiTF.Override.approval_status(mission.id) do
      :approved -> :pass
      :not_required -> :pass
      :rejected -> :terminal_fail
      :pending -> handle_pending(mission)
    end
  rescue
    _ -> :wait
  end

  @impl true
  def terminal(mission, :retries_exhausted, _artifact) do
    # Whether we got here via :rejected or via the auto-reject branch in
    # verdict/2, the legacy reason is the same shape: human reviewer or
    # auto-timeout rejection. We don't know which here, so use a generic
    # message — both verdict paths can also have logged the specific reason.
    Logger.warning("Quest #{mission.id}: awaiting_approval terminated as failed")
    GiTF.Missions.fail_quest(mission.id, "Human review rejected")
    :ok
  end

  def terminal(_mission, _kind, _artifact), do: :ok

  # -- Pending path: timeout → auto-approve / auto-reject / alert -----------

  defp handle_pending(mission) do
    if Approval.timed_out?(mission.id) do
      timeout_h = Approval.timeout_hours()

      if Approval.mission_max_risk(mission.id) == :critical do
        # Never auto-approve critical work — but don't wait forever either.
        # Past the terminal escalation window with no human decision, fail
        # the mission (fail-safe: unreviewed critical work is not merged).
        if Approval.critical_escalation_timed_out?(mission.id) do
          esc_h = Approval.critical_escalation_hours()

          Logger.warning(
            "Quest #{mission.id} critical-risk and unapproved after #{esc_h}h escalation window — failing (fail-safe)"
          )

          GiTF.Observability.Alerts.dispatch_webhook(
            :approval_escalation_failed,
            "Quest #{mission.id} critical-risk auto-FAILED: no human approval within #{esc_h}h"
          )

          GiTF.Override.reject(
            mission.id,
            "No human approval within critical escalation window",
            %{rejected_by: "auto_escalation"}
          )

          :terminal_fail
        else
          Logger.warning(
            "Quest #{mission.id} timeout reached but mission is critical-risk, refusing auto-approve"
          )

          GiTF.Observability.Alerts.dispatch_webhook(
            :approval_timeout_critical,
            "Quest #{mission.id} timed out after #{timeout_h}h but is critical-risk — requires human approval"
          )

          :wait
        end
      else
        cond do
          # A disagreement was already recorded — hold quietly for the
          # human, don't re-run revalidation every verdict poll.
          Approval.revalidation_disagreement?(mission.id) ->
            :wait

          Approval.revalidate(mission) ->
            Logger.info(
              "Quest #{mission.id} auto-approved after #{timeout_h}h timeout (dark factory mode)"
            )

            GiTF.Override.approve(mission.id, %{
              approved_by: "auto_timeout",
              notes: "Auto-approved after #{timeout_h}h (re-validated)"
            })

            :pass

          true ->
            # The mission already PASSED validation to get here; a
            # re-validation failure on unchanged code is a signal
            # disagreement, not new evidence of bad work (msn-aa92dd was
            # trashed by exactly this — a security-scan flap an hour after
            # a 10/10 pass). Never destroy validated work on a machine
            # disagreement: withhold auto-approve, keep the approval
            # pending, and alert the operator.
            Approval.note_revalidation_disagreement(mission, timeout_h)
            :wait
        end
      end
    else
      :wait
    end
  end
end
