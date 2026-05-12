defmodule GiTF.Phases.Design do
  @moduledoc """
  Design phase handler.

  Design produces one or more strategy artifacts (`minimal` / `normal` /
  `complex` by default) and then unconditionally advances — the *review*
  phase is what supplies a pass/fail verdict over the produced designs.
  So this handler's verdict is `:advance` once the design artifact is
  present; there is no `before_advance` side effect on the way out
  (`promote_selected_design` belongs to `GiTF.Phases.Review`, which runs
  it when review picks a variant).

  Pair with a workflow phase config like:

      - id: design
        handler: GiTF.Phases.Design
        strategies: [minimal, normal, complex]
        reads: [requirements, research]
        produces: design
        next: review

  ## Not yet captured

  Parallel-strategy execution and the design tournament (audit gap #7)
  still live in the legacy `Major.Orchestrator` path; this module is the
  seam where that work will land. The `standard` workflow continues to
  use the legacy path until that extraction is complete.
  """

  @behaviour GiTF.Phase

  @impl true
  def start(mission, %GiTF.Workflow.Phase{id: id}, _ctx) do
    GiTF.Major.Orchestrator.dispatch_phase(id, mission)
  end

  @impl true
  def verdict(_artifact), do: :advance
end
