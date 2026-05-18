defmodule GiTF.Phases.Sync do
  @moduledoc """
  Sync phase handler.

  Sync executes the configured merge strategy for the mission's sector —
  `auto_merge`, `pr_branch`, or `manual` — and writes a `sync` artifact.
  `start/3` delegates to the legacy `Orchestrator.dispatch_phase("sync",
  mission)` → `start_merge/1`, which is the only place that knows how to
  resolve the sector's `sync_strategy` and run the actual merge.

  The merge is effectively synchronous: by the time `start_merge/1`
  returns, the `sync` artifact has been written. So the workflow's
  `:advance` verdict typically fires on the next poll.

  `verdict/2` advances once the artifact is present; a `{"status":
  "failed"}` artifact routes to `:fail` so an operator-authored
  workflow can branch on a failed merge.
  """

  @behaviour GiTF.Phase

  @impl true
  def start(mission, %GiTF.Workflow.Phase{id: id}, _ctx) do
    GiTF.Major.Orchestrator.dispatch_phase(id, mission)
  end

  @impl true
  def verdict(artifact) when is_map(artifact) do
    if GiTF.Workflow.Verdict.artifact_failed?(artifact), do: :fail, else: :advance
  end

  def verdict(_), do: :wait
end
