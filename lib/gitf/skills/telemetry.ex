defmodule GiTF.Skills.Telemetry do
  @moduledoc """
  Telemetry helpers for the skill library. Emits structured events that
  downstream observability consumers (metrics, logs, traces) can attach to.

  Event names:

    * `[:gitf, :skills, :retrieved]` — a ghost's pre-spawn retrieval
      pulled N skills from the Archive pool.
    * `[:gitf, :skills, :installed]` — N skills were written into a
      worktree's `.claude/skills/` directory.
    * `[:gitf, :skills, :refined]` — an existing skill was updated based
      on validator feedback.
    * `[:gitf, :skills, :drafted]` — a new skill was drafted from a
      validation failure.
    * `[:gitf, :skills, :critic_rejected]` — the critic rejected a
      proposal before it reached the Archive.
    * `[:gitf, :skills, :refiner_no_op]` — the refiner ran but decided
      no skill change was warranted.
    * `[:gitf, :skills, :applied_success]` / `[:gitf, :skills, :applied_failure]`
      — success/failure counter bumps for skills applied to a completed
      mission.
  """

  @doc "Emit when a pre-spawn retrieval returns a list of skills."
  def emit_retrieved(skill_ids, sector_id) when is_list(skill_ids) do
    safe_emit(
      [:gitf, :skills, :retrieved],
      %{count: length(skill_ids)},
      %{sector_id: sector_id, skill_ids: skill_ids}
    )
  end

  @doc "Emit when skills are written into a worktree."
  def emit_installed(skill_ids, worktree_path) when is_list(skill_ids) do
    safe_emit(
      [:gitf, :skills, :installed],
      %{count: length(skill_ids)},
      %{worktree: worktree_path, skill_ids: skill_ids}
    )
  end

  @doc "Emit when the refiner updates an existing skill."
  def emit_refined(skill_id, scope, reason) do
    safe_emit(
      [:gitf, :skills, :refined],
      %{},
      %{skill_id: skill_id, scope: scope, reason: reason}
    )
  end

  @doc "Emit when the refiner drafts a new skill."
  def emit_drafted(skill_id, scope, reason) do
    safe_emit(
      [:gitf, :skills, :drafted],
      %{},
      %{skill_id: skill_id, scope: scope, reason: reason}
    )
  end

  @doc "Emit when the critic rejects a proposal."
  def emit_critic_rejected(reason, action) do
    safe_emit(
      [:gitf, :skills, :critic_rejected],
      %{},
      %{reason: reason, action: action}
    )
  end

  @doc "Emit when the refiner decides no change is warranted."
  def emit_refiner_no_op(reason) do
    safe_emit([:gitf, :skills, :refiner_no_op], %{}, %{reason: reason})
  end

  @doc "Emit when skills applied to a completed mission get success bumps."
  def emit_applied_success(skill_ids, mission_id) when is_list(skill_ids) do
    safe_emit(
      [:gitf, :skills, :applied_success],
      %{count: length(skill_ids)},
      %{mission_id: mission_id, skill_ids: skill_ids}
    )
  end

  @doc "Emit when skills applied to a failed mission get failure bumps."
  def emit_applied_failure(skill_ids, mission_id) when is_list(skill_ids) do
    safe_emit(
      [:gitf, :skills, :applied_failure],
      %{count: length(skill_ids)},
      %{mission_id: mission_id, skill_ids: skill_ids}
    )
  end

  # -- Private -----------------------------------------------------------------

  defp safe_emit(event, measurements, metadata) do
    GiTF.Telemetry.emit(event, measurements, metadata)
  rescue
    _ -> :ok
  end
end
