defmodule GiTF.Phases.Review do
  @moduledoc """
  Review phase handler.

  Owns:

    * **Verdict** — read `review.approved` boolean from the artifact.
    * **Side effect** — when advancing to planning (whether via `:pass`
      or via `on_exhausted: :advance` after exceeding redesign budget),
      promote the review's `selected_design` onto the canonical
      `"design"` artifact key so the planning phase reads the chosen
      variant.

  Maps directly onto the legacy `Major.Orchestrator.handle_review_result/1`
  semantic. The legacy path stays in place for `workflow_id == "standard"`
  missions; this module owns review behaviour for any non-standard
  workflow.

  Pair with a workflow phase config like:

      - id: review
        handler: GiTF.Phases.Review
        on_pass: planning
        on_fail: design
        max_retries: 2
        on_exhausted: advance   # give up but proceed to planning
  """

  @behaviour GiTF.Phase

  @impl true
  def start(mission, %GiTF.Workflow.Phase{id: id}, _ctx) do
    GiTF.Major.Orchestrator.dispatch_phase(id, mission)
  end

  @impl true
  def verdict(%{"approved" => true}), do: :pass
  def verdict(%{"approved" => false}), do: :fail
  def verdict(_), do: :inconclusive

  @impl true
  def before_advance(mission, verdict, artifact)
      when verdict in [:pass, :advance] and is_map(artifact) do
    GiTF.Major.Orchestrator.promote_selected_design(mission.id, artifact)
    :ok
  end

  def before_advance(_mission, _verdict, _artifact), do: :ok

  # The YAML's `max_retries: 2` is a template default; if the mission's
  # sector has a high-confidence intelligence profile recommending a
  # different redesign budget, honour that. Mirrors the legacy
  # `reject_design/2` / `handle_review_result/1` policy so operator
  # rejections and ghost-driven review failures share the same ceiling.
  @impl true
  def max_retries(mission, _phase_config) do
    GiTF.Major.Orchestrator.max_redesign_for(Map.get(mission, :sector_id))
  end
end
