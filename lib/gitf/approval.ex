defmodule GiTF.Approval do
  @moduledoc """
  Human-approval domain for missions whose risk profile (or operator
  override) requires a gate before merging.

  This module owns:

    * **Phase entry** (`request/1`) — transition the mission into the
      `awaiting_approval` phase, raise an approval request via
      `GiTF.Override.request_approval/1`, and fire the operator webhook.
    * **Legacy advance loop** (`handle_result/1`) — drives the next step
      based on the current approval status (`:approved` → merge,
      `:rejected` → fail, `:pending` → wait or auto-approve on timeout).
    * **Timeout policy** (`timed_out?/1`, `timeout_hours/0`,
      `mission_max_risk/1`) — the auto-approve / auto-reject machinery
      the dark-factory mode uses when a human reviewer doesn't act.
    * **Re-validation** (`revalidate/1`) — sanity check that completed
      impl ops still pass verification before auto-approving.

  Both the legacy orchestrator dispatch path (`handle_result/1` is
  called from `Major.Orchestrator.advance_quest/1`'s
  awaiting_approval branch) and the workflow phase handler
  (`GiTF.Phases.AwaitingApproval`) call into this module — the workflow
  path uses the predicates directly (`timed_out?`, `mission_max_risk`,
  `revalidate`) and runs the same side-effect graph in `verdict/2`.
  """

  require Logger

  alias GiTF.{Archive, Audit, Missions, Observability, Override}
  alias GiTF.Config.Provider, as: ConfigProvider

  @doc """
  Transitions the mission into the `awaiting_approval` phase, raises
  the approval request, and notifies operators via the
  `:approval_requested` webhook.

  Returns `{:ok, "awaiting_approval"}` once the transition + request are
  recorded.
  """
  @spec request(map()) :: {:ok, String.t()} | {:error, term()}
  def request(mission) do
    with {:ok, _} <-
           Missions.transition_phase(
             mission.id,
             "awaiting_approval",
             "Validation passed, awaiting human approval"
           ) do
      Override.request_approval(mission.id)

      Observability.Alerts.dispatch_webhook(
        :approval_requested,
        "Quest #{mission.id} awaiting human approval: #{String.slice(mission.goal, 0, 80)}"
      )

      {:ok, "awaiting_approval"}
    end
  end

  @doc """
  Drives the legacy advance loop for a mission in `awaiting_approval`.
  Reads the current approval status and either merges, fails, waits, or
  takes the auto-approve timeout path.

  The workflow path uses `GiTF.Phases.AwaitingApproval.verdict/2`
  instead — same decision tree expressed as verdict atoms.
  """
  @spec handle_result(map()) :: {:ok, String.t()} | {:error, term()}
  def handle_result(mission) do
    case Override.approval_status(mission.id) do
      status when status in [:approved, :not_required] ->
        {:ok, mission} = Missions.get(mission.id)
        GiTF.Publish.merge(mission)

      :rejected ->
        Logger.warning("Quest #{mission.id} rejected by human reviewer")
        Missions.fail_quest(mission.id, "Human review rejected")

      :pending ->
        handle_pending(mission)
    end
  end

  defp handle_pending(mission) do
    if timed_out?(mission.id) do
      timeout_h = timeout_hours()

      if mission_max_risk(mission.id) == :critical do
        # Critical-risk missions never auto-approve. But they must not wait
        # forever either — the mission max-age/cost caps exempt
        # awaiting_approval, so without a terminal window an unattended
        # critical mission stalls indefinitely. After a long escalation
        # grace with no human decision, fail (reject) it: NOT merging
        # unreviewed critical work is the fail-safe outcome.
        if critical_escalation_timed_out?(mission.id) do
          esc_h = critical_escalation_hours()

          Logger.warning(
            "Quest #{mission.id} critical-risk and unapproved after #{esc_h}h escalation window — failing (fail-safe, not merging)"
          )

          Observability.Alerts.dispatch_webhook(
            :approval_escalation_failed,
            "Quest #{mission.id} critical-risk auto-FAILED: no human approval within #{esc_h}h"
          )

          Override.reject(mission.id, "No human approval within critical escalation window", %{
            rejected_by: "auto_escalation"
          })

          Missions.fail_quest(mission.id, "Critical-risk approval timed out (#{esc_h}h)")
        else
          Logger.warning(
            "Quest #{mission.id} timeout reached but mission is critical-risk, refusing auto-approve"
          )

          Observability.Alerts.dispatch_webhook(
            :approval_timeout_critical,
            "Quest #{mission.id} timed out after #{timeout_h}h but is critical-risk — requires human approval"
          )

          {:ok, "awaiting_approval"}
        end
      else
        if revalidate(mission) do
          Logger.info(
            "Quest #{mission.id} auto-approved after #{timeout_h}h timeout (dark factory mode)"
          )

          Override.approve(mission.id, %{
            approved_by: "auto_timeout",
            notes: "Auto-approved after #{timeout_h}h (re-validated)"
          })

          {:ok, mission} = Missions.get(mission.id)
          GiTF.Publish.merge(mission)
        else
          Logger.warning("Quest #{mission.id} re-validation failed, rejecting auto-approve")

          Override.reject(mission.id, "Re-validation failed during auto-approve", %{
            rejected_by: "auto_timeout"
          })

          Missions.fail_quest(mission.id, "Auto-approve failed re-validation")
        end
      end
    else
      {:ok, "awaiting_approval"}
    end
  end

  @doc """
  Spot-check that a sample of completed impl ops still passes
  verification. Returns `true` when there are no ops to check (vacuously
  fresh), or when up to three sampled ops all verify; `false` if any
  fail or if `Audit.verify_job/1` crashes.
  """
  @spec revalidate(map()) :: boolean()
  def revalidate(mission) do
    impl_jobs = for op <- mission.ops, !op[:phase_job], op.status == "done", do: op

    if impl_jobs == [] do
      true
    else
      sample = Enum.take(impl_jobs, 3)

      results =
        Enum.map(sample, fn op ->
          case Audit.verify_job(op.id) do
            {:ok, :pass, _} -> true
            _ -> false
          end
        end)

      Enum.all?(results)
    end
  rescue
    e ->
      Logger.warning(
        "Re-validation crashed for mission #{mission.id}: #{Exception.message(e)}, rejecting"
      )

      false
  end

  @doc """
  Has the pending approval request for `mission_id` exceeded its
  timeout window?
  """
  @spec timed_out?(String.t()) :: boolean()
  def timed_out?(mission_id) do
    case Archive.find_one(:approval_requests, fn r ->
           r.mission_id == mission_id and r.status == "pending"
         end) do
      nil ->
        false

      request ->
        hours_elapsed = DateTime.diff(DateTime.utc_now(), request.requested_at, :second) / 3600
        hours_elapsed > timeout_hours()
    end
  end

  @doc """
  Auto-approval timeout in hours, configurable via
  `[:approvals, :timeout_hours]` (defaults to 1).
  """
  @spec timeout_hours() :: number()
  def timeout_hours, do: ConfigProvider.get([:approvals, :timeout_hours], 1)

  @doc """
  Terminal escalation window (hours) for critical-risk missions that never
  received a human decision. Past this, the mission is failed rather than
  left waiting forever. Configurable via `[:approvals,
  :critical_escalation_hours]` (defaults to 24).
  """
  @spec critical_escalation_hours() :: number()
  def critical_escalation_hours,
    do: ConfigProvider.get([:approvals, :critical_escalation_hours], 24)

  @doc """
  Has a pending critical-risk approval exceeded the terminal escalation
  window (measured from the request time)?
  """
  @spec critical_escalation_timed_out?(String.t()) :: boolean()
  def critical_escalation_timed_out?(mission_id) do
    case Archive.find_one(:approval_requests, fn r ->
           r.mission_id == mission_id and r.status == "pending"
         end) do
      nil ->
        false

      request ->
        hours_elapsed = DateTime.diff(DateTime.utc_now(), request.requested_at, :second) / 3600
        hours_elapsed > critical_escalation_hours()
    end
  end

  @doc """
  The highest `risk_level` across a mission's ops. Used by the
  auto-approve gate so `:critical`-risk missions never bypass the
  human reviewer.
  """
  @spec mission_max_risk(String.t()) :: :critical | :high | :normal
  def mission_max_risk(mission_id) do
    case Archive.get(:missions, mission_id) do
      nil ->
        :normal

      mission ->
        ops = Map.get(mission, :ops, [])

        cond do
          Enum.any?(ops, fn op -> Map.get(op, :risk_level) == :critical end) -> :critical
          Enum.any?(ops, fn op -> Map.get(op, :risk_level) == :high end) -> :high
          true -> :normal
        end
    end
  end
end
