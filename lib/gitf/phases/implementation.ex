defmodule GiTF.Phases.Implementation do
  @moduledoc """
  Implementation phase handler.

  Unlike most phases, implementation doesn't have a phase ghost that
  writes a single artifact. It has N regular ops (each spawned by
  `Major.spawn_ready_jobs/2`) that do real work in worktrees; the
  phase is "done" when all the impl ops are terminal (done/failed).

  This handler bridges that gap for the workflow Advancer:

    * `start/3` delegates to `Orchestrator.dispatch_phase("implementation",
      _)` → the legacy `start_implementation/1` which transitions to
      the phase and asks the Major to spawn ready ops (including the
      tournament-mode variant fan-out, when enabled).
    * `verdict/2` returns `:wait` while any non-phase op is still
      pending or running and `:advance` once they're all terminal.
      Mixed terminal states (some done, some failed) still advance —
      the validation phase that follows decides whether the impl
      output was good enough.

  Without this handler the generic `Workflow.Verdict.compute/2` looks
  for an `"implementation"` artifact key that nothing writes, so the
  mission stalls forever at implementation when it dispatches via the
  workflow path. (This is the cause of the long-standing simulator +
  E2E stalls where triage and the impl op both complete but the
  mission stays `active`.)
  """

  @behaviour GiTF.Phase

  @impl true
  def start(mission, %GiTF.Workflow.Phase{id: id}, _ctx) do
    GiTF.Major.Orchestrator.dispatch_phase(id, mission)
  end

  @impl true
  def verdict(mission, _artifact) do
    impl_ops =
      (Map.get(mission, :ops) || [])
      |> Enum.reject(&Map.get(&1, :phase_job, false))

    cond do
      impl_ops == [] ->
        # Major hasn't created any impl ops yet (planning may still be
        # rolling them out); wait.
        :wait

      Enum.all?(impl_ops, &(&1.status in ["done", "failed", "rejected"])) ->
        :advance

      true ->
        :wait
    end
  end
end
