defmodule GiTF.Major.WorkflowBridge do
  @moduledoc """
  THE WORKFLOW BRIDGE — the adapter between the mission's journey and a
  declarative workflow definition. When a mission carries a
  `workflow_id`, the phase sequence comes from the workflow DSL rather
  than the Orchestrator's hardcoded ladder; this module resolves the
  workflow, asks `GiTF.Workflow.Advancer` what to do next, and turns
  that decision back into an orchestrator action.

  Every path through here can fall back to the legacy ladder, because
  the workflow layer is default-off and a mission must never be stranded
  by a definition that failed to load.

  The scars are all about how a bridge fails:

    * WORKFLOW DRIFT (a phase id no longer defined — a deploy renamed it,
      or the workflow was switched mid-mission) HOLDS the mission in its
      current phase. Neither rewinding nor dropping to the legacy ladder
      is safe when the map has changed underneath a mission in flight;
      the Advancer has already paged the operator.
    * msn-dd29a1: retries-exhausted set `status` directly instead of
      calling `fail_quest`. The mission sat as failed/validation with no
      reason, the reviewer was never told, and because its phase never
      became terminal the Janitor re-advanced the record every three
      minutes, forever.
    * `:complete` gives the just-ended phase's handler first refusal —
      `Phases.Scoring.terminal(:complete)` marks post-processing done,
      because `Phases.Publish.before_advance/3` already made the mission
      user-visibly completed and the standard `complete_quest` would be
      wrong there.
    * A handler that RAISES falls back to the legacy starter rather than
      taking the mission down with it.
  """

  require Logger

  alias GiTF.Archive
  alias GiTF.Major.Orchestrator

  @doc """
  True when this mission should be advanced by a workflow definition
  rather than the hardcoded phase ladder.
  """
  def workflow_dispatch_active?(mission) do
    Application.get_env(:gitf, :workflow_dsl_enabled, true) == true and
      is_binary(Map.get(mission, :workflow_id)) and
      Map.get(mission, :workflow_id) != ""
  end

  @doc """
  Advance `mission` (currently at `phase`) via its workflow definition,
  falling back to the legacy ladder if the workflow will not load.
  """
  def advance_via_workflow(mission, phase) do
    case GiTF.Workflow.resolve(mission.workflow_id, mission.sector_id) do
      {:ok, workflow} ->
        decision = GiTF.Workflow.Advancer.decide(mission, workflow)

        Logger.info(
          "Orchestrator: workflow=#{workflow.name} decision=#{inspect(decision)} for #{mission.id}@#{phase}"
        )

        handle_workflow_decision(decision, mission, phase, workflow)

      {:error, reason} ->
        Logger.warning(
          "Workflow #{mission.workflow_id} did not load for mission #{mission.id}: #{inspect(reason)}; legacy"
        )

        Orchestrator.advance_via_legacy(mission, phase)
    end
  end

  defp handle_workflow_decision({:wait, p}, _mission, _phase, _wf), do: {:ok, p}

  defp handle_workflow_decision({:dispatch, next_id}, mission, _phase, workflow),
    do: dispatch_via_handler(workflow, next_id, mission)

  defp handle_workflow_decision(:complete, mission, _phase, workflow) do
    # Give the just-ended phase's handler first refusal — e.g.,
    # `Phases.Scoring.terminal(:complete)` calls `mark_post_processing_done/1`
    # since the mission was already user-visibly completed by
    # `Phases.Publish.before_advance/3`, so the standard `complete_quest`
    # would be wrong here.
    case GiTF.Workflow.Advancer.invoke_terminal(mission, workflow, :complete) do
      {:ok, :handled} ->
        {:ok, "completed"}

      :default ->
        GiTF.Missions.complete_quest(mission.id, "workflow reached :end")
        {:ok, "completed"}
    end
  end

  defp handle_workflow_decision({:retry, source, target}, mission, _phase, workflow) do
    Archive.update(:missions, mission.id, fn m ->
      retries = Map.get(m, :phase_retries) || %{}
      Map.put(m, :phase_retries, Map.update(retries, source, 1, &(&1 + 1)))
    end)

    dispatch_via_handler(workflow, target, mission)
  end

  defp handle_workflow_decision({:retries_exhausted, p}, mission, _phase, workflow) do
    case GiTF.Workflow.Advancer.invoke_terminal(mission, workflow, :retries_exhausted) do
      {:ok, :handled} ->
        Logger.info("Quest #{mission.id}: workflow ended at #{p} (handler-terminated)")
        {:ok, "failed"}

      :default ->
        Logger.warning(
          "Quest #{mission.id}: workflow exhausted retries on phase=#{p}, marking failed"
        )

        # fail_quest, not a bare status write: it records the reason, moves
        # the phase to terminal, and fires the notification. Setting status
        # directly left msn-dd29a1 as failed/validation/no-reason — the
        # reviewer was never told, and the Janitor re-advanced the record
        # every 3 minutes because its phase never became terminal.
        GiTF.Missions.fail_quest(
          mission.id,
          "workflow exhausted retries on phase #{p}"
        )

        {:ok, "failed"}
    end
  end

  # Workflow drift (phase id no longer defined — deploy renamed it, or
  # workflow switched mid-mission): HOLD in the current phase. Neither
  # rewinding nor the legacy path is safe here; the Advancer already
  # alerted the operator.
  defp handle_workflow_decision({:error, {:workflow_drift, _}}, _mission, phase, _wf),
    do: {:ok, phase}

  defp handle_workflow_decision({:error, reason}, mission, phase, _wf) do
    Logger.warning(
      "Workflow dispatch error for mission #{mission.id}: #{inspect(reason)}; falling back to legacy"
    )

    Orchestrator.advance_via_legacy(mission, phase)
  end

  # Dispatches `phase_id` for a workflow-path mission. Prefers the
  # workflow phase's `handler:` (a `GiTF.Phase` implementation's `start/3`)
  # so the handler can run logic legacy keeps in `start_<phase>/1`; falls
  # back to `dispatch_phase/2` (the legacy starter map) when no handler
  # is configured or the module hasn't loaded a `start/3`.
  defp dispatch_via_handler(workflow, phase_id, mission) do
    case GiTF.Workflow.phase(workflow, phase_id) do
      {:ok, %GiTF.Workflow.Phase{handler: handler} = phase_config}
      when not is_nil(handler) ->
        if Code.ensure_loaded?(handler) and function_exported?(handler, :start, 3) do
          ctx = %{workflow: workflow, sector_id: Map.get(mission, :sector_id)}

          try do
            handler.start(mission, phase_config, ctx)
          rescue
            e ->
              Logger.warning(
                "Handler #{inspect(handler)}.start/3 raised for mission #{mission.id}@#{phase_id}: " <>
                  "#{Exception.message(e)}; falling back to legacy starter"
              )

              Orchestrator.dispatch_phase(phase_id, mission)
          end
        else
          Orchestrator.dispatch_phase(phase_id, mission)
        end

      _ ->
        Orchestrator.dispatch_phase(phase_id, mission)
    end
  end
end
