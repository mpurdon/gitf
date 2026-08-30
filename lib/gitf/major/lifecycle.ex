defmodule GiTF.Major.Lifecycle do
  @moduledoc """
  THE LIFECYCLE — the persona that watches the clock and the meter. It
  answers the three questions asked on EVERY advance tick, before any
  phase work is considered: has this mission run too long, has it spent
  too much, and is the artifact in front of us real?

  It also owns the post-mortem side of a death: classifying a failure
  reason into a type, and feeding the failed ops back to the learning
  loop.

  Every scar here is about failing in the right DIRECTION:

    * A healthy run 24 hit $22.50 by validation round 1 and was killed
      mid-fix-loop against config that said $40 — the cap hard-defaulted
      to $20 without ever consulting `Budget.config_budget()`. Invisible
      while CLI costs booked as model-unknown pocket change; fatal the
      moment per-model booking recorded real notional costUSD.
    * The old budget rescue returned `spent = 0.0`, so ONE malformed cost
      record permanently disarmed the cap for every mission. The check
      now fails CLOSED — but "unverifiable" and "exceeded" are distinct
      outcomes: an uncomputable budget HOLDS the mission and pages the
      operator rather than destroying work over a bookkeeping glitch.
    * Mission age is measured in AWAKE hours, not wall hours. The box
      idle-stops, and a wake was force-completing the entire queue that
      had "aged" through the sleep.
    * A compacted artifact stub is not a usable artifact: treating it as
      one made resumed missions read nil complexity → `:complex` → a full
      pipeline re-run of phases they had already paid for.
  """

  require Logger

  alias GiTF.Config.Provider, as: Config

  # Phases where neither the clock nor the meter may act, because the thing
  # the mission is waiting for is not the factory: the human gates
  # (`Missions.human_gate_phases/0`, one list so a gate added later cannot
  # miss this), plus the two ends of the journey.
  #
  # For `awaiting_input` the reason is sharper than for approval: that gate
  # never auto-answers, so a mission held on a question would otherwise be
  # force-completed for the crime of the operator being asleep — the
  # decision it escalated silently replaced by a timeout, which is the
  # exact outcome the no-auto-answer policy exists to prevent.
  defp unmetered_phases, do: ["completed", "pending"] ++ GiTF.Missions.human_gate_phases()

  # -- The meter ---------------------------------------------------------------

  @doc false
  def over_budget?(mission) do
    status = Map.get(mission, :status, "pending")
    phase = Map.get(mission, :current_phase, "pending")

    # Skip the check once the mission is user-visibly done — post-processing
    # cost is bounded by the scoring-failure cap, not the mission budget.
    # A mission held at a human gate spends nothing while it waits, so the
    # meter has nothing to say about it either.
    if status == "completed" or phase in unmetered_phases() do
      false
    else
      # Fail CLOSED: an unverifiable budget blocks advancement (the arm
      # above distinguishes held-vs-exceeded). The old rescue returned
      # spent=0.0, which meant one malformed cost record permanently
      # disarmed the cap for every mission.
      case mission_budget_snapshot(mission) do
        {:ok, {cap, spent}} -> spent > cap
        {:error, _reason} -> true
      end
    end
  end

  @doc false
  def mission_budget_snapshot(mission) do
    # Resolution order: per-mission cap, explicit [major] override, then the
    # provider-scoped mission budget ([costs.provider_mission_budgets] —
    # cli/Max caps are notional, so they're set generous). This used to
    # hard-default to $20 without ever consulting Budget.config_budget():
    # invisible while CLI costs booked as model-unknown pocket change, but
    # the moment per-model booking recorded REAL notional costUSD, a healthy
    # run 24 hit $22.50 by validation round 1 and was killed mid-fix-loop
    # against config that said $40.
    cap =
      Map.get(mission, :cost_cap_usd) ||
        Config.get([:major, :mission_cost_cap_usd]) ||
        GiTF.Budget.config_budget()

    spent = GiTF.Costs.for_quest(mission.id) |> GiTF.Costs.total()
    {:ok, {cap * 1.0, spent}}
  rescue
    e ->
      Logger.error("Mission budget snapshot failed for #{mission.id}: #{Exception.message(e)}")

      {:error, Exception.message(e)}
  end

  # -- The clock ---------------------------------------------------------------

  @doc false
  def quest_timed_out?(mission) do
    case mission[:inserted_at] do
      %DateTime{} = started ->
        # Awake hours, not wall hours — idle-stop sleeps must not count
        # toward a mission's age (a wake was force-completing the queue).
        hours = GiTF.Clock.awake_elapsed(started) / 3600
        phase = Map.get(mission, :current_phase, "pending")
        status = Map.get(mission, :status, "pending")
        # Don't timeout missions that are completed or held at a human gate.
        # Also skip missions that are user-visibly completed but still running
        # async post-processing (status="completed" with phase="scoring") —
        # post-processing has its own failure path that doesn't regress status.
        status != "completed" and
          phase not in unmetered_phases() and
          hours > max_quest_age_hours()

      _ ->
        false
    end
  end

  @doc false
  def max_quest_age_hours, do: Config.get([:major, :mission_timeout_hours], 24)

  # -- Artifact honesty --------------------------------------------------------

  # Returns true if the artifact was a fallback from a failed parse (empty ghost output).
  @doc false
  def artifact_failed?(artifact) when is_map(artifact) do
    # A compacted stub is not a usable artifact: treating it as one made
    # resumed missions read nil complexity -> :complex -> full pipeline
    # re-run on phases they'd already paid for.
    Map.get(artifact, "parse_failed", false) == true or
      Map.get(artifact, "compacted", false) == true
  end

  def artifact_failed?(_), do: false

  # -- Death and its lessons ---------------------------------------------------

  @failure_patterns [
    {~r/timed?\s*out|timeout|exceeded.*h\b/i, :timeout},
    {~r/budget|cost|spend/i, :budget_exceeded},
    {~r/compil|syntax|undefined function/i, :compilation_error},
    {~r/test.*fail|assertion|assert/i, :test_failure},
    {~r/context.*overflow|context.*handoff|context.*limit/i, :context_overflow},
    {~r/validation.*fail|validator|verdict.*fail/i, :validation_failure},
    {~r/quality.*gate|quality.*below|score.*below/i, :quality_gate_failure},
    {~r/security|vulnerab|secret/i, :security_gate_failure},
    {~r/merge.*conflict|conflict.*in/i, :merge_conflict},
    {~r/provider.*unavail|all.*providers.*down|circuit.*open/i, :provider_unavailable},
    {~r/rejected|human.*review.*rejected/i, :review_rejected},
    {~r/no sector|auto.assign.*fail/i, :configuration_error}
  ]

  @doc false
  def classify_reason(reason) when is_binary(reason) do
    Enum.find_value(@failure_patterns, :unknown, fn {pattern, type} ->
      if Regex.match?(pattern, reason), do: type
    end)
  end

  def classify_reason(_), do: :unknown

  # Store triage-vs-outcome data for future accuracy analysis.
  # Links the original triage complexity to the final quality score so
  # patterns like "ops triaged as simple but scored < 70" can be detected.
  @doc false
  def ingest_failure_outcome(mission_id) do
    Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
      case GiTF.Missions.get(mission_id) do
        {:ok, mission} ->
          mission.ops
          |> Enum.filter(&(&1.status == "failed"))
          |> Enum.each(fn op ->
            try do
              GiTF.Intel.FailureAnalysis.analyze_failure(op.id)
            rescue
              e ->
                Logger.warning(
                  "ingest_failure_outcome: per-op analysis failed for #{op.id}: " <>
                    Exception.message(e)
                )

                :ok
            end
          end)

          GiTF.Intel.SectorProfile.invalidate(mission.sector_id)

        _ ->
          :ok
      end
    end)
  rescue
    _ -> :ok
  end
end
