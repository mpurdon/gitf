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
          # No review rule — review reads the design, so reaching it from
          # triage means there is nothing to review. See standard.yaml.
          - when: "artifact.skip_flags.skip_planning != true"
            then: planning
          - else: implementation

  `before_advance/3` does the two artifact-driven side effects the
  legacy orchestrator triage handler does:

    * sets `mission.pipeline_mode` from the triaged complexity
      (`Decisions.pipeline_mode_for_complexity/1`), leaving it alone when
      the operator forced a mode at start;
    * when the artifact says the bug isn't reproducible *and* the
      evidence is strong (`GiTF.Triage.strong_no_work_evidence?/1` — a
      regex check that can't live in a `next:` expression), writes
      `no_work_needed: true` back onto the triage artifact so the first
      conditional rule above can short-circuit the mission to `end`.

  Weak "not reproducible" evidence is intentionally *not* flagged, so
  those missions fall through to the `skip_*` checks and run the full
  pipeline — matching the legacy behaviour.

  ## Which path actually runs

  **This one, for `standard` too.** `workflow_dispatch_active?/1` requires
  only `workflow_dsl_enabled` (default **true**) and a non-empty
  `workflow_id`, so any mission carrying a workflow id — which `standard`
  does — advances through `advance_via_workflow/2` and these callbacks.
  `advance_via_legacy/2` is the fallback, not the default.

  This docstring previously claimed the opposite ("still routes triage via
  the legacy path; `workflow_dispatch_active?/1` excludes `standard`"), and
  it cost a deploy: a routing fix was applied to the legacy orchestrator
  only, shipped, and changed nothing, because the live path reads
  `standard.yaml`'s `next:` rules.

  Phase routing consequently lives in two places — these YAML rules and
  `Orchestrator.Decisions.next_phase_after_triage/2` — which is one too
  many. Until they are collapsed, `standard.yaml` is the one that decides;
  change it first and treat `Decisions` as the emergency fallback it is.
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
  def verdict(artifact) when is_map(artifact) do
    if GiTF.Workflow.Verdict.artifact_failed?(artifact), do: :fail, else: :advance
  end

  def verdict(_), do: :inconclusive

  @impl true
  def before_advance(mission, verdict, artifact)
      when verdict in [:pass, :advance] and is_map(artifact) do
    complexity = Triage.complexity_from_string(artifact["complexity"]) || :complex

    unless Decisions.forced_pipeline_mode?(mission) do
      Missions.update(mission.id, %{
        pipeline_mode: Decisions.pipeline_mode_for_complexity(complexity)
      })
    end

    bug_reproducible = artifact["bug_reproducible"]
    evidence = artifact["bug_evidence"] || ""

    # Only written when it changed. The artifact is the record of what triage
    # concluded; a forced-full pipeline overrides the routing it implies via
    # standard.yaml's `mission.pipeline_mode_forced` rule, not by rewriting
    # the model's output here.
    if bug_reproducible == false and Triage.strong_no_work_evidence?(evidence) do
      Missions.store_artifact(mission.id, "triage", Map.put(artifact, "no_work_needed", true))
    end

    :ok
  end

  def before_advance(_mission, _verdict, _artifact), do: :ok

  @impl true
  def terminal(mission, :complete, artifact) when is_map(artifact) do
    # Conditional `next:` resolved `artifact.no_work_needed == true` to
    # `end`. Match the legacy `complete_quest_no_work_needed/2` semantics:
    # store a "preflight" artifact, emit `[:gitf, :mission, :no_work_needed]`
    # telemetry, complete the mission, dispatch an operator webhook, and
    # record to the ledger.
    Orchestrator.complete_quest_no_work_needed(mission, artifact["bug_evidence"] || "")
    :ok
  end

  def terminal(_mission, _kind, _artifact), do: :ok
end
