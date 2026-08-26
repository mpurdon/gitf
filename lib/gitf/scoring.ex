defmodule GiTF.Scoring do
  @moduledoc """
  Post-completion scoring domain — the work that runs *after* a mission
  is user-visibly completed (PR opened, push landed, or skipped):

    * `finish/1` — store triage feedback for the sector intelligence
      loop, ingest per-op outcomes for the learning loop, mark
      `post_processing_status` done, and reap ghost worktrees + branches.
    * `post_processing_exhausted?/1` — heuristic the legacy advance loop
      (and `Phases.Scoring`) use to give up on post-processing rather
      than wait forever for a scoring ghost that keeps crashing.

  Both the legacy orchestrator dispatch path (`advance_via_legacy/2`) and the
  workflow phase handler (`GiTF.Phases.Scoring`) call into this module.
  The actual scoring ghost is still spawned by
  `Major.Orchestrator.dispatch_phase("scoring", _)` → `start_scoring/1`,
  which stays on the orchestrator because it shares the
  `spawn_phase_ghost/4` helper with every other phase starter.
  """

  require Logger

  alias GiTF.{Archive, Missions}

  # When a scoring ghost has failed this many times without producing a
  # scoring artifact, the legacy advance loop gives up rather than wait
  # forever — scoring is post-completion, so dropping it doesn't undo
  # the user-visible delivery.
  @max_failures 3

  @doc """
  Has post-processing been retried too many times without producing a
  scoring artifact? `true` means the orchestrator / phase handler
  should mark post-processing failed and stop spawning new scoring
  ghosts.
  """
  @spec post_processing_exhausted?(map()) :: boolean()
  def post_processing_exhausted?(mission) do
    has_artifact? = not is_nil(Missions.get_artifact(mission.id, "scoring"))

    failed_scoring_ops =
      Enum.count(mission.ops, fn op ->
        op[:phase_job] && Map.get(op, :phase) == "scoring" && op.status == "failed"
      end)

    not has_artifact? and failed_scoring_ops >= @max_failures
  end

  @doc """
  Wrap up a mission after scoring produced its artifact. Records triage
  feedback for the sector intelligence loop, kicks the per-op outcome
  ingester, flips `post_processing_status` to `"done"`, and reaps the
  mission's ghost worktrees + branches.

  Returns whatever `Missions.mark_post_processing_done/1` returns —
  callers (legacy `check_and_advance` and `Phases.Scoring.terminal/3`)
  treat it as the final transition.
  """
  @spec finish(map()) :: {:ok, String.t()} | {:error, term()}
  def finish(mission) do
    scoring = Missions.get_artifact(mission.id, "scoring")

    if scoring do
      score = Map.get(scoring, "overall_score", 0)
      Logger.info("Quest #{mission.id} scored #{score}/100")
      record_triage_feedback(mission, score)
    end

    ingest_mission_outcome(mission)

    # User-visible status was already "completed" since publish's
    # after_publish; this just advances current_phase to "completed"
    # and flips post_processing_status to "done".
    result = Missions.mark_post_processing_done(mission.id)

    # Reap ghost worktrees + branches now that the mission is fully done.
    GiTF.Major.Orchestrator.cleanup_mission_branch(mission)

    result
  end

  # -- Helpers ----------------------------------------------------------------

  defp record_triage_feedback(mission, score) do
    research = Missions.get_artifact(mission.id, "research")
    triage_complexity = if research, do: Map.get(research, "complexity"), else: nil
    pipeline_mode = Map.get(mission, :pipeline_mode)

    Archive.insert(:triage_feedback, %{
      mission_id: mission.id,
      sector_id: mission.sector_id,
      triage_complexity: triage_complexity,
      pipeline_mode: pipeline_mode,
      quality_score: score,
      completed_at: DateTime.utc_now()
    })
  rescue
    e -> Logger.debug("Triage feedback recording failed: #{Exception.message(e)}")
  end

  # Async per-op outcome analysis + sector profile invalidation so the
  # learning loop sees this mission's results without blocking the
  # caller. Failures inside the Task are logged but never raised.
  defp ingest_mission_outcome(mission) do
    Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
      mission.ops
      |> Enum.reject(& &1[:phase_job])
      |> Enum.each(fn op ->
        try do
          case op.status do
            "done" -> GiTF.Intel.analyze_success(op.id)
            "failed" -> GiTF.Intel.FailureAnalysis.analyze_failure(op.id)
            _ -> :ok
          end
        rescue
          e ->
            Logger.warning(
              "ingest_mission_outcome: per-op analysis failed for #{op.id}: " <>
                Exception.message(e)
            )

            :ok
        end
      end)

      GiTF.Intel.SectorProfile.invalidate(mission.sector_id)
    end)
  rescue
    e ->
      Logger.warning("ingest_mission_outcome failed for #{mission.id}: #{Exception.message(e)}")

      :ok
  end
end
