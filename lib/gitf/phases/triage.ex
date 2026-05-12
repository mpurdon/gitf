defmodule GiTF.Phases.Triage do
  @moduledoc """
  Triage phase handler.

  Triage classifies a mission's complexity and emits `skip_flags`. As a
  workflow phase it advances unconditionally to its `next:` target once
  the `triage` artifact is present (a `{"status": "failed"}` artifact
  routes to `:fail` so a workflow can branch on it).

  ## Not yet captured — data-dependent routing

  The legacy `Major.Orchestrator` triage handler does two things this
  module deliberately does **not** replicate, because the workflow DSL's
  `next:` / `on_pass:` / `on_fail:` model cannot express them:

    * **skip-flag routing** — `route_to_first_unskipped_phase/2` jumps
      straight to research / requirements / design / review / planning /
      implementation depending on which `skip_flags` triage set. The
      DSL would need a conditional `next:` (an expression over the
      artifact) to model this.
    * **`bug_reproducible == false` short-circuit** — when triage proves
      the bug isn't reproducible with strong evidence, the legacy path
      completes the mission immediately ("no work needed"). Again, that
      is an artifact-conditional terminal transition the current schema
      can't express.

  The legacy path also writes `pipeline_mode` from the triaged
  complexity. Until conditional transitions exist in the workflow
  schema, the `standard` workflow keeps using the legacy path; this
  handler is here for non-standard workflows whose triage step is a
  plain "classify, then proceed".
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
