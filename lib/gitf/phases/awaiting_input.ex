defmodule GiTF.Phases.AwaitingInput do
  @moduledoc """
  Awaiting-input phase handler — the workflow-DSL face of the input gate.

  It is the *secondary* path, and deliberately so. `GiTF.Inquiry.Gate`
  intercepts above the workflow/legacy fork in
  `Orchestrator.advance_mission_phase/1`, because any phase can raise a
  question and no workflow YAML should have to declare a phase it never
  routes to (a workflow that omitted it would send every held mission
  down `GiTF.Workflow.Advancer`'s WORKFLOW DRIFT path). This handler
  exists so a workflow that DOES want to name the gate — to hang a
  timeout or a comment on it — has something to name.

  `start/3` delegates to `Orchestrator.dispatch_phase("awaiting_input",
  mission)` → `GiTF.Inquiry.Gate.start/1`, which refuses to park a
  mission that has no open question.

  `verdict/2` mirrors `GiTF.Phases.AwaitingApproval.verdict/2`'s shape:

    * anything still open → `:wait`, after escalating whatever has gone
      stale. This gate NEVER auto-answers; see `GiTF.Inquiry`'s moduledoc
      for why the approval gate's auto-decide is safe and this one's
      would not be.
    * everything answered → `Gate.resume_asking_phase/1` moves the
      mission back to the phase that asked and re-dispatches it, then
      this returns `:wait`.

  That last `:wait` is not a stall — it means *do not route me, I have
  routed myself*. The return phase is dynamic (it is whichever phase
  asked), and a workflow's `on_pass:` is static, so the handler owns the
  transition and the Advancer's next look finds the mission already
  somewhere else. `Phases.AwaitingApproval` sets the same precedent by
  running its side-effect graph inside `verdict/2`.

  Pair with a workflow phase config like:

      - id: awaiting_input
        handler: GiTF.Phases.AwaitingInput
        on_pass: awaiting_input
        on_fail: awaiting_input
        max_retries: 0
        on_exhausted: fail
  """

  @behaviour GiTF.Phase

  require Logger

  alias GiTF.Inquiry
  alias GiTF.Inquiry.Gate
  alias GiTF.Major.Orchestrator

  @impl true
  def start(mission, %GiTF.Workflow.Phase{id: id}, _ctx) do
    Orchestrator.dispatch_phase(id, mission)
  end

  @impl true
  def verdict(mission, _artifact) do
    if Inquiry.open?(mission.id) do
      Inquiry.escalate_stale(mission.id)
      :wait
    else
      Gate.resume_asking_phase(mission)
      :wait
    end
  rescue
    _ -> :wait
  end

  @impl true
  def terminal(mission, kind, _artifact) do
    # Nothing here can exhaust: verdict/2 only ever returns :wait, so
    # the mission leaves this phase by being answered or not at all. If
    # a workflow contrives to terminate it anyway, say so plainly rather
    # than failing a mission whose only problem is an unanswered question.
    Logger.warning(
      "Quest #{mission.id}: awaiting_input terminated as #{inspect(kind)} while holding for " <>
        "an operator answer — the questions are still open in GiTF.Inquiry"
    )

    :ok
  end
end
