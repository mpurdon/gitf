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

  # The one phase whose meaning is "the factory has stopped and a human is
  # the blocker".
  @gate_phase "awaiting_approval"

  @doc """
  Where a mission stands relative to the human-approval gate, for the
  pipeline widgets:

    * `:held` — sitting on the gate right now. A human is the blocker.
    * `:decided` — a human (or the auto-timeout) answered. Read the
      `approval` artifact for who and when.
    * `:skipped` — the mission passed the gate point without anything ever
      being asked of a human. Nothing to approve, so nothing happened.
    * `:future` — the gate has not been reached. It may still fire.

  Both the mission-detail stepper and the overview mini-pipeline call
  this, so they cannot render the same mission differently — the previous
  arrangement had each aliasing `awaiting_approval` to `sync`
  independently, and msn-ac0539 spent twelve hours blocked on a human
  while both widgets showed "sync — actively merging".

  `:skipped` is only ever claimed once the mission is past the gate point
  (at `sync` or later) or terminal. A gate that may still fire renders
  `:future`, never dimmed. A mission that died before ever reaching the
  gate is `:skipped` rather than `:future`: it is not waiting for
  anything, and a pending-looking step on a dead mission is the same lie
  in a different colour.

  Truthfulness comes from `GiTF.Override.approval_status/1` — `:not_required`
  means no request record AND no approval artifact, i.e. nothing was ever
  asked of a human. It is consulted only once the cheap phase-position
  checks have already decided the gate is behind us.
  """
  @spec gate_state(map()) :: :future | :held | :decided | :skipped
  def gate_state(mission) when is_map(mission) do
    cond do
      current_phase(mission) == @gate_phase -> :held
      not past_gate?(mission) -> :future
      not is_binary(Map.get(mission, :id)) -> :future
      true -> from_status(Override.approval_status(mission.id))
    end
  rescue
    # A widget must not take the page down because the store hiccuped.
    # `:future` claims nothing about what a human did.
    _ -> :future
  end

  def gate_state(_), do: :future

  defp from_status(:not_required), do: :skipped
  # A request still open past the gate point is an anomaly, not a skip —
  # say a human is the blocker rather than dimming the step.
  defp from_status(:pending), do: :held
  defp from_status(_), do: :decided

  defp current_phase(mission), do: Map.get(mission, :current_phase) || "pending"

  @terminal_statuses ~w(completed closed killed failed)

  defp past_gate?(mission) do
    Map.get(mission, :status) in @terminal_statuses or advanced_past_gate?(mission)
  end

  # Runtime lookup, not a module attribute: a compile-time call into
  # `Orchestrator` from here would build a dependency cycle.
  defp advanced_past_gate?(mission) do
    phases = GiTF.Major.Orchestrator.phases()

    case {Enum.find_index(phases, &(&1 == @gate_phase)),
          Enum.find_index(phases, &(&1 == current_phase(mission)))} do
      {gate, current} when is_integer(gate) and is_integer(current) -> current > gate
      _ -> false
    end
  end

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
        "Quest #{mission.id} awaiting human approval: #{String.slice(mission.goal, 0, 80)}" <>
          approvals_link()
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
        cond do
          # A disagreement was already recorded — hold quietly for the
          # human, don't re-run revalidation every advance sweep.
          revalidation_disagreement?(mission.id) ->
            {:ok, "awaiting_approval"}

          revalidate(mission) ->
            Logger.info(
              "Quest #{mission.id} auto-approved after #{timeout_h}h timeout (dark factory mode)"
            )

            Override.approve(mission.id, %{
              approved_by: "auto_timeout",
              notes: "Auto-approved after #{timeout_h}h (re-validated)"
            })

            {:ok, mission} = Missions.get(mission.id)
            GiTF.Publish.merge(mission)

          true ->
            # The mission already PASSED validation to get here; a
            # re-validation failure on unchanged code is a signal
            # disagreement, not new evidence of bad work (msn-aa92dd was
            # trashed by exactly this — a security-scan flap an hour after a
            # 10/10 pass). Never destroy validated work on a machine
            # disagreement: withhold auto-approve, keep the approval
            # pending, and tell the operator about the discrepancy.
            note_revalidation_disagreement(mission, timeout_h)
            {:ok, "awaiting_approval"}
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
        # Awake time, not wall time: the box idle-stops, and an approval
        # must not "time out" during hours nobody could have acted. The
        # boot grace stops a wake from immediately auto-deciding.
        hours_elapsed = GiTF.Clock.awake_elapsed(request.requested_at) / 3600
        hours_elapsed > timeout_hours() and not GiTF.Clock.in_boot_grace?()
    end
  end

  @doc """
  Has a revalidation disagreement already been recorded on the pending
  request? Used to alert and spot-check once, then hold quietly for the
  human instead of re-running revalidation every advance sweep.
  """
  @spec revalidation_disagreement?(String.t()) :: boolean()
  def revalidation_disagreement?(mission_id) do
    case Archive.find_one(:approval_requests, fn r ->
           r.mission_id == mission_id and r.status == "pending"
         end) do
      nil -> false
      request -> request[:revalidation_disagreement] == true
    end
  end

  @doc """
  Records a validation/re-validation disagreement on the pending approval
  request and alerts the operator — exactly once per request. The mission
  stays in `awaiting_approval`: work that passed validation is never
  auto-rejected on a machine disagreement (fail toward the human).
  """
  @spec note_revalidation_disagreement(map(), number()) :: :ok
  def note_revalidation_disagreement(mission, timeout_h) do
    Logger.warning(
      "Quest #{mission.id} re-validation disagreed with original validation — withholding auto-approve, keeping for human review"
    )

    case Archive.find_one(:approval_requests, fn r ->
           r.mission_id == mission.id and r.status == "pending"
         end) do
      nil ->
        :ok

      request ->
        Archive.update(:approval_requests, request.id, fn r ->
          Map.put(r, :revalidation_disagreement, true)
        end)
    end

    Observability.Alerts.dispatch_webhook(
      :approval_revalidation_disagreement,
      "Quest #{mission.id}: re-validation failed after #{timeout_h}h timeout but original validation passed — auto-approve withheld, human review needed" <>
        approvals_link()
    )

    :ok
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
        # Awake time + boot grace, same reasoning as timed_out?/1 — an
        # idle weekend must not terminally fail critical missions.
        hours_elapsed = GiTF.Clock.awake_elapsed(request.requested_at) / 3600
        hours_elapsed > critical_escalation_hours() and not GiTF.Clock.in_boot_grace?()
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

  # Deep link into the approvals dashboard when the operator has configured
  # the server's own URL ([server] url); alerts stay plain text otherwise.
  defp approvals_link do
    case GiTF.Config.server_url() do
      url when is_binary(url) and url != "" ->
        "\n#{String.trim_trailing(url, "/")}/dashboard/approvals"

      _ ->
        ""
    end
  end
end
