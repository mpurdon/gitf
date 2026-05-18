defmodule GiTF.Phases.Publish do
  @moduledoc """
  Publish phase handler.

  Publish runs synchronously (no ghost): renders the PR/push, stores a
  `publish` artifact, and kicks off post-completion outcome tracking
  (`GiTF.Outcomes`). Then either:

    * **Success path** — `:advance`. `before_advance/3` flips the mission
      to user-visibly completed (`Missions.mark_user_visible_completed/1`).
      Routing follows `next:` (standard: `next: scoring`), so async
      scoring runs as post-processing.

    * **Failure path** — a `{"status": "pr_failed" | "push_failed"}`
      artifact returns `:terminal_fail`. The mission is failed loudly
      (`fail_quest`) — the pipeline's sole user-facing output is the PR;
      claiming "completed" without one is the worst kind of silent failure.

  Maps directly onto the legacy `Major.Orchestrator.after_publish/1`
  semantic. The legacy path keeps using `start_publish/1` (which calls
  `after_publish` itself); the workflow path lands here.
  """

  @behaviour GiTF.Phase

  require Logger

  @impl true
  def start(mission, _phase_config, _ctx) do
    GiTF.Major.Orchestrator.publish_step(mission)
  end

  @impl true
  def verdict(_mission, %{"status" => s}) when s in ["pr_failed", "push_failed"],
    do: :terminal_fail

  def verdict(_mission, artifact) when is_map(artifact) do
    # `pr_failed`/`push_failed` are publish-domain failures, but a generic
    # `status: "failed"` (string or atom-keyed) artifact is also a failure
    # — share that check with the rest of the phase handlers.
    if GiTF.Workflow.Verdict.artifact_failed?(artifact), do: :terminal_fail, else: :advance
  end

  def verdict(_mission, _), do: :wait

  @impl true
  def before_advance(mission, :advance, _artifact) do
    GiTF.Missions.mark_user_visible_completed(mission.id)

    GiTF.Telemetry.emit([:gitf, :mission, :user_visible_completed], %{}, %{
      mission_id: mission.id,
      name: Map.get(mission, :name)
    })

    :ok
  end

  def before_advance(_mission, _verdict, _artifact), do: :ok

  @impl true
  def terminal(mission, :retries_exhausted, artifact) do
    status = (is_map(artifact) && artifact["status"]) || "unknown"
    error = is_map(artifact) && artifact["error"]
    reason = "Publish failed: status=#{status} error=#{inspect(error)}"

    Logger.warning("Quest #{mission.id}: #{reason} — marking mission failed")

    GiTF.Telemetry.emit([:gitf, :mission, :publish_failed], %{}, %{
      mission_id: mission.id,
      status: status
    })

    GiTF.Missions.fail_quest(mission.id, reason)
    :ok
  end

  def terminal(_mission, _kind, _artifact), do: :ok
end
