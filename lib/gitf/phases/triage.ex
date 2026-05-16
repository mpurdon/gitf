defmodule GiTF.Phases.Triage do
  @moduledoc """
  Triage phase handler.

  Triage classifies a mission's complexity and emits `skip_flags`. As a
  workflow phase it advances on completion (a `{"status": "failed"}`
  artifact routes to `:fail` so a workflow can branch on it); a
  conditional `next:` then routes on the artifact:

      - id: triage
        handler: GiTF.Phases.Triage
        next:
          - when: "artifact.no_work_needed == true"
            then: end
          - when: "artifact.skip_flags.skip_research != true"
            then: research
          - when: "artifact.skip_flags.skip_requirements != true"
            then: requirements
          - when: "artifact.skip_flags.skip_design != true"
            then: design
          - when: "artifact.skip_flags.skip_review != true"
            then: review
          - when: "artifact.skip_flags.skip_planning != true"
            then: planning
          - else: implementation

  `before_advance/3` does the two artifact-driven side effects the
  legacy orchestrator triage handler does:

    * sets `mission.pipeline_mode` from the triaged complexity
      (`GiTF.Major.Orchestrator.Decisions.pipeline_mode_for_complexity/1`);
    * when the artifact says the bug isn't reproducible *and* the
      evidence is strong (`GiTF.Triage.strong_no_work_evidence?/1` — a
      regex check that can't live in a `next:` expression), writes
      `no_work_needed: true` back onto the triage artifact so the first
      conditional rule above can short-circuit the mission to `end`.

  Weak "not reproducible" evidence is intentionally *not* flagged, so
  those missions fall through to the `skip_*` checks and run the full
  pipeline — matching the legacy behaviour.

  ## Not yet captured

  The `standard` workflow still routes triage via the legacy path
  (`workflow_dispatch_active?/1` excludes `"standard"`); migrating it
  means replacing `standard.yaml`'s `triage: next: research` with the
  conditional list above and exercising the full suite against the
  workflow dispatch path.
  """

  @behaviour GiTF.Phase

  alias GiTF.{Missions, Triage}
  alias GiTF.Major.Orchestrator
  alias GiTF.Major.Orchestrator.Decisions

  @impl true
  def start(mission, %GiTF.Workflow.Phase{id: id}, _ctx) do
    Orchestrator.dispatch_phase(id, mission)
  end

  @impl true
  def verdict(%{"status" => s}) when s in ["failed", "fail"], do: :fail
  def verdict(artifact) when is_map(artifact), do: :advance
  def verdict(_), do: :inconclusive

  @impl true
  def before_advance(mission, verdict, artifact)
      when verdict in [:pass, :advance] and is_map(artifact) do
    complexity =
      Triage.complexity_from_string(artifact["complexity"] || artifact[:complexity]) || :complex

    Missions.update(mission.id, %{pipeline_mode: Decisions.pipeline_mode_for_complexity(complexity)})

    bug_reproducible = Map.get(artifact, "bug_reproducible", Map.get(artifact, :bug_reproducible))
    evidence = Map.get(artifact, "bug_evidence", Map.get(artifact, :bug_evidence, "")) || ""

    if bug_reproducible == false and Triage.strong_no_work_evidence?(evidence) do
      Missions.store_artifact(mission.id, "triage", Map.put(artifact, "no_work_needed", true))
    end

    :ok
  rescue
    _ -> :ok
  end

  def before_advance(_mission, _verdict, _artifact), do: :ok

  @impl true
  def terminal(mission, :complete, artifact) when is_map(artifact) do
    # Conditional `next:` resolved `artifact.no_work_needed == true` to
    # `end`. Match the legacy `complete_quest_no_work_needed/2` semantics:
    # store a "preflight" artifact, emit `[:gitf, :mission, :no_work_needed]`
    # telemetry, complete the mission, dispatch an operator webhook, and
    # record to the ledger.
    evidence = Map.get(artifact, "bug_evidence", Map.get(artifact, :bug_evidence, "")) || ""
    Orchestrator.complete_quest_no_work_needed(mission, evidence)
    :ok
  rescue
    _ -> :ok
  end

  def terminal(_mission, _kind, _artifact), do: :ok
end
