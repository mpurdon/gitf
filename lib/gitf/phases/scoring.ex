defmodule GiTF.Phases.Scoring do
  @moduledoc """
  Scoring phase handler.

  Scoring records a quality assessment of the merged work. In the
  standard pipeline it runs as **async post-processing after the mission
  is already user-visibly completed** (`Phases.Publish.before_advance/3`
  flips the user-visible status). So success and failure don't mean
  "complete the mission" / "fail the mission" — they flip
  `post_processing_status`:

    * `scoring` artifact present → `:advance` (`next: end` → workflow
      `:complete` → handler `terminal(:complete, artifact)` →
      `Missions.mark_post_processing_done/1`).
    * No artifact yet, but ≥ 3 failed scoring ops →
      `:terminal_fail` (workflow `:retries_exhausted` → handler
      `terminal(:retries_exhausted, artifact)` →
      `Missions.mark_post_processing_failed/2`). Mirrors
      `Orchestrator.scoring_post_processing_exhausted?/1`.
    * Otherwise → `:wait` (still scoring).

  `before_advance(:advance)` runs the legacy `finish_scored/1`
  side effects — record triage feedback against the score, ingest
  per-op outcome data — by delegating to the still-private
  orchestrator path. (We don't `mark_post_processing_done` here:
  `:advance` is followed by routing to `:end` and only the workflow's
  `:complete` decision should flip post-processing.)

  Operator-authored workflows that simply end at `scoring` get the
  ordinary `:complete` semantic via the same `terminal(:complete, _)`
  path — which calls `mark_post_processing_done/1` rather than
  `complete_quest/2`. That matches the standard pipeline; an
  operator-authored "scoring is the terminal phase of a mission that
  wasn't already publish-completed" workflow would need a different
  handler.
  """

  @behaviour GiTF.Phase

  require Logger

  @impl true
  def start(mission, %GiTF.Workflow.Phase{id: id}, _ctx) do
    GiTF.Major.Orchestrator.dispatch_phase(id, mission)
  end

  @impl true
  def verdict(mission, artifact) do
    cond do
      is_map(artifact) ->
        if GiTF.Workflow.Verdict.artifact_failed?(artifact), do: :terminal_fail, else: :advance

      GiTF.Major.Orchestrator.scoring_post_processing_exhausted?(mission) ->
        :terminal_fail

      true ->
        :wait
    end
  end

  @impl true
  def terminal(mission, :complete, _artifact) do
    # Mirrors the legacy `check_and_advance("scoring", &finish_scored/1)` —
    # records triage feedback against the score, ingests per-op outcomes,
    # flips `post_processing_status` to "done", reaps worktrees/branch.
    GiTF.Major.Orchestrator.finish_scored(mission)
    :ok
  end

  def terminal(mission, :retries_exhausted, _artifact) do
    Logger.warning(
      "Quest #{mission.id}: scoring exhausted retries — marking post_processing_status=failed"
    )

    GiTF.Missions.mark_post_processing_failed(mission.id, "scoring exhausted retries")
    :ok
  end

  def terminal(_mission, _kind, _artifact), do: :ok
end
