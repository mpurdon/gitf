defmodule GiTF.Phases.Default do
  @moduledoc """
  Bridge handler that delegates to the orchestrator's existing hardcoded
  `start_<phase>/1` functions.

  Used as the implicit default when a workflow phase doesn't name its
  own handler module. Lets the workflow DSL ship before all 13 phase
  starters are extracted into their own modules — the migration is
  progressive: as each phase is rewritten as a first-class
  `GiTF.Phases.<Name>` module, the workflow YAML points at the new one
  and `Default` covers the rest.

  ## Why public delegate functions

  The orchestrator's `start_<phase>/1` are private. Rather than mass-
  promote them to `def`, this module references them via a public
  dispatch function added on `GiTF.Major.Orchestrator` for exactly
  this purpose. M3's full integration removes the indirection.
  """

  @behaviour GiTF.Phase

  @impl true
  def start(mission, %GiTF.Workflow.Phase{id: phase_id}, _ctx) do
    GiTF.Major.Orchestrator.dispatch_phase(phase_id, mission)
  end

  @impl true
  def verdict(_artifact), do: :advance
end
