defmodule GiTF.Workflow.Verdict do
  @moduledoc """
  Pure verdict computation for a mission's current phase.

  The orchestrator advances a mission by asking: *given this artifact,
  which workflow branch do I follow?* This module captures that
  decision in one testable place, mirroring the legacy
  `check_*_and_advance` / `handle_*_result` semantics:

  | Verdict     | Meaning                                                                   |
  |-------------|---------------------------------------------------------------------------|
  | `:wait`     | Phase still running — no artifact yet, or artifact incomplete             |
  | `:advance`  | Phase complete; follow the workflow's `next:` field                       |
  | `:pass`     | Verdict-driven phase succeeded; follow `on_pass:`                         |
  | `:fail`     | Verdict-driven phase failed; follow `on_fail:` (subject to `max_retries`) |
  Phase-specific helpers live as private functions so adding a new phase
  type is a one-place change. The artifact-failed convention
  (`artifact["status"] == "failed"`) matches `Lifecycle.artifact_failed?`.

  Workflow termination (the `:end` sentinel in `next:`) is signalled by
  the Advancer when it walks `Workflow.next_phase/3`, not by Verdict —
  Verdict reports phase-level decisions only.
  """

  alias GiTF.Missions

  @type verdict :: :wait | :advance | :pass | :fail

  @doc """
  Computes the verdict for `mission` at `phase_id`, given the
  workflow's phase config (which tells us whether the phase is
  unconditional `next` vs verdict-driven `on_pass`/`on_fail`).

  Returns `:wait` when the artifact for the phase isn't present yet —
  the phase ghost is still running.
  """
  @spec compute(map(), GiTF.Workflow.Phase.t()) :: verdict()
  def compute(mission, phase_config) do
    phase_id = phase_config.id
    artifact = Missions.get_artifact(mission.id, phase_id)

    cond do
      is_nil(artifact) ->
        :wait

      artifact_failed?(artifact) ->
        # Verdict-driven phases route to on_fail; unconditional phases
        # surface the error upstream via the dispatcher. Either way :fail.
        :fail

      GiTF.Workflow.Phase.verdict_driven?(phase_config) ->
        verdict_for(phase_id, artifact)

      true ->
        :advance
    end
  end

  # -- Phase-specific verdict logic ------------------------------------------

  # Review's verdict comes from the `approved` boolean on the review
  # artifact. Mirrors `Orchestrator.handle_review_result/1`.
  defp verdict_for("review", %{"approved" => true}), do: :pass
  defp verdict_for("review", %{"approved" => false}), do: :fail
  defp verdict_for("review", _), do: :wait

  # Validation's verdict is in `overall_verdict` (string or atom) on the
  # validation artifact. Delegates to `Phases.Validation.verdict/1` so
  # both the workflow generic path and the handler-driven path share
  # one source of truth. `:inconclusive` here collapses to `:fail` so
  # retries kick in.
  defp verdict_for("validation", artifact) do
    case GiTF.Phases.Validation.verdict(artifact) do
      :pass -> :pass
      _ -> :fail
    end
  end

  # Design has multiple strategies; the legacy path treats it as
  # always-advance once each strategy artifact is present. We treat
  # `design` itself as :advance — `review` is what supplies the verdict.
  defp verdict_for("design", _artifact), do: :advance

  # Default for unknown verdict-driven phases: assume artifact's own
  # `status` field. Lets operators add custom phases that emit a
  # `{"status": "pass" | "fail"}` artifact without changing this module.
  defp verdict_for(_phase_id, %{"status" => "pass"}), do: :pass
  defp verdict_for(_phase_id, %{"status" => "passed"}), do: :pass
  defp verdict_for(_phase_id, %{"status" => "fail"}), do: :fail
  defp verdict_for(_phase_id, %{"status" => "failed"}), do: :fail
  defp verdict_for(_phase_id, _), do: :advance

  # -- Helpers ---------------------------------------------------------------

  @doc """
  Whether an artifact represents a phase-level failure. Matches both
  string- and atom-keyed `status: "failed"` so handlers that read
  JSON-via-Archive artifacts and handlers that build atom-keyed maps in
  tests agree. Phase handlers should call this from `verdict/1` /
  `verdict/2` rather than open-coding the check.
  """
  @spec artifact_failed?(term()) :: boolean()
  def artifact_failed?(%{"status" => "failed"}), do: true
  def artifact_failed?(%{status: "failed"}), do: true
  def artifact_failed?(_), do: false
end
