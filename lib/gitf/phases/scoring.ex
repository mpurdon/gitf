defmodule GiTF.Phases.Scoring do
  @moduledoc """
  Scoring phase handler.

  Scoring records a quality assessment of the merged work. As a workflow
  phase it is unconditional: once the `scoring` artifact is present the
  workflow advances (typically to `end`). A `{"status": "failed"}`
  artifact routes to `:fail` so an operator-authored workflow can retry
  or branch on it; everything else is `:advance`.

  Pair with a workflow phase config like:

      - id: scoring
        handler: GiTF.Phases.Scoring
        reads: [validation, requirements]
        produces: scoring
        next: end

  ## Not yet captured

  In the legacy `standard` path, scoring runs as *async post-processing*
  after the mission is already user-visibly "completed": repeated scoring
  failures flip `post_processing_status` to `failed` (via
  `Missions.mark_post_processing_failed/2`) rather than failing the
  mission, and success calls `mark_post_processing_done/1` instead of
  `complete_quest/2`. That two-phase-completion semantic is specific to
  the standard pipeline and is *not* modelled here — operator-authored
  workflows that end at `scoring` get the ordinary `:complete` →
  `complete_quest` behaviour. The `standard` workflow therefore stays on
  the legacy path until this is reconciled.
  """

  @behaviour GiTF.Phase

  @impl true
  def start(mission, %GiTF.Workflow.Phase{id: id}, _ctx) do
    GiTF.Major.Orchestrator.dispatch_phase(id, mission)
  end

  @impl true
  def verdict(%{"status" => s}) when s in ["failed", "fail"], do: :fail
  def verdict(artifact) when is_map(artifact), do: :advance
  def verdict(_), do: :inconclusive
end
