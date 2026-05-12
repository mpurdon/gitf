defmodule GiTF.Workflow.Advancer do
  @moduledoc """
  Glues `Workflow.Verdict` together with `Workflow.next_phase/3` to
  decide what the orchestrator should do for a mission's current phase.

  Returns a `decision` that the orchestrator can act on:

    * `{:wait, phase_id}` — phase is still running; no advance
    * `{:dispatch, next_phase_id}` — call `dispatch_phase(next_phase_id, mission)`
    * `:complete` — workflow reached `:end`; mark the mission complete
    * `{:retry, phase_id}` — verdict was :fail, on_fail loops back, and
      the retry budget is not yet exhausted; re-dispatch the same phase
    * `{:retries_exhausted, phase_id}` — fail loop hit `max_retries`;
      orchestrator should mark the mission failed
    * `{:error, reason}` — workflow misconfigured (cycle, missing branch)

  Pure: no Archive writes, no telemetry. The orchestrator owns side
  effects and decides what to do with each decision.
  """

  alias GiTF.Workflow
  alias GiTF.Workflow.Phase
  alias GiTF.Workflow.Verdict

  @type decision ::
          {:wait, String.t()}
          | {:dispatch, String.t()}
          | :complete
          | {:retry, source :: String.t(), target :: String.t()}
          | {:retries_exhausted, String.t()}
          | {:error, term()}

  @doc """
  Computes the next action for `mission` under `workflow`.

  `mission.current_phase` is the phase whose artifact we examine. The
  retry counter is read from `mission.phase_retries[phase_id]` if
  present (orchestrator increments on each :retry decision).
  """
  @spec decide(map(), Workflow.t()) :: decision()
  def decide(mission, workflow) do
    phase_id = mission_current_phase(mission)

    case Workflow.phase(workflow, phase_id) do
      {:error, :not_found} ->
        # Mission's current_phase isn't in this workflow — most likely
        # the operator switched workflows mid-mission to one that
        # doesn't include the current phase. The orchestrator should
        # advance to the workflow's entry phase.
        case Workflow.entry_phase(workflow) do
          {:ok, %Phase{id: entry}} -> {:dispatch, entry}
          {:error, _} = err -> err
        end

      {:ok, %Phase{} = phase_config} ->
        artifact = GiTF.Missions.get_artifact(mission.id, phase_id)
        ctx = %{artifact: artifact, mission: mission}

        case compute_verdict(mission, phase_config, artifact) do
          :wait ->
            {:wait, phase_id}

          :advance ->
            run_before_advance(phase_config, mission, :advance, artifact)
            advance_via(workflow, phase_id, :advance, ctx)

          :pass ->
            run_before_advance(phase_config, mission, :pass, artifact)
            advance_via(workflow, phase_id, :pass, ctx)

          :fail ->
            run_before_advance(phase_config, mission, :fail, artifact)
            handle_fail(mission, workflow, phase_config, ctx)

          :inconclusive ->
            {:wait, phase_id}
        end
    end
  end

  # Verdict resolution: handler.verdict/1 takes precedence when the
  # phase declares one; otherwise the generic Verdict module decides.
  defp compute_verdict(mission, %Phase{handler: handler} = phase_config, artifact)
       when not is_nil(handler) do
    cond do
      is_nil(artifact) ->
        # Without an artifact there's nothing for the handler to inspect;
        # fall through to Verdict (which returns :wait in this case).
        Verdict.compute(mission, phase_config)

      ensure_exported?(handler, :verdict, 1) ->
        try do
          handler.verdict(artifact)
        rescue
          _ -> Verdict.compute(mission, phase_config)
        end

      true ->
        Verdict.compute(mission, phase_config)
    end
  end

  defp compute_verdict(mission, phase_config, _artifact),
    do: Verdict.compute(mission, phase_config)

  defp run_before_advance(%Phase{handler: handler}, mission, verdict, artifact)
       when not is_nil(handler) do
    if ensure_exported?(handler, :before_advance, 3) do
      try do
        handler.before_advance(mission, verdict, artifact)
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  defp run_before_advance(_phase_config, _mission, _verdict, _artifact), do: :ok

  defp ensure_exported?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end

  # -- Internals -------------------------------------------------------------

  defp advance_via(workflow, phase_id, verdict, ctx) do
    case Workflow.next_phase(workflow, phase_id, verdict, ctx) do
      {:ok, :end} -> :complete
      {:ok, next} when is_binary(next) -> {:dispatch, next}
      {:error, _} = err -> err
    end
  end

  defp handle_fail(mission, workflow, %Phase{} = phase_config, ctx) do
    phase_id = phase_config.id
    retries = retry_count(mission, phase_id)

    if retries >= phase_config.max_retries do
      handle_exhaustion(workflow, phase_config, ctx)
    else
      case Workflow.next_phase(workflow, phase_id, :fail, ctx) do
        {:ok, :end} -> :complete
        {:ok, next} when is_binary(next) -> {:retry, phase_id, next}
        {:error, _} = err -> err
      end
    end
  end

  # `on_exhausted` policy:
  #   :fail (default) → mark mission failed
  #   :advance        → fall through to on_pass target (review's
  #                     "give up but proceed" semantic)
  #   "<phase_id>"    → force-dispatch to a specific phase
  defp handle_exhaustion(workflow, %Phase{} = phase_config, ctx) do
    case phase_config.on_exhausted do
      :fail ->
        {:retries_exhausted, phase_config.id}

      :advance ->
        case Workflow.next_phase(workflow, phase_config.id, :pass, ctx) do
          {:ok, :end} -> :complete
          {:ok, next} when is_binary(next) -> {:dispatch, next}
          {:error, _} = err -> err
        end

      target when is_binary(target) ->
        if target == "end", do: :complete, else: {:dispatch, target}

      _ ->
        {:retries_exhausted, phase_config.id}
    end
  end

  defp mission_current_phase(mission) do
    Map.get(mission, :current_phase) || mission["current_phase"] || "pending"
  end

  defp retry_count(mission, phase_id) do
    case Map.get(mission, :phase_retries) || mission["phase_retries"] || %{} do
      %{} = retries -> Map.get(retries, phase_id, 0) || Map.get(retries, to_string(phase_id), 0)
      _ -> 0
    end
  end
end
