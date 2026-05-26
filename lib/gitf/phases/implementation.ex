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
    * `before_advance/3` (when `:lsp_validation_enabled` is on) runs
      a best-effort LSP diagnostic sweep over the changed files and
      surfaces errors via telemetry. The check does NOT block the
      advance — validation is the gate that decides pass/fail. The
      goal here is observability: by the time validation reads the
      diagnostics, they're already warm in the LSP cache.

  Without this handler the generic `Workflow.Verdict.compute/2` looks
  for an `"implementation"` artifact key that nothing writes, so the
  mission stalls forever at implementation when it dispatches via the
  workflow path. (This is the cause of the long-standing simulator +
  E2E stalls where triage and the impl op both complete but the
  mission stays `active`.)
  """

  @behaviour GiTF.Phase

  require Logger

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

  @impl true
  def before_advance(mission, :advance, _artifact) do
    if Application.get_env(:gitf, :lsp_validation_enabled, false) do
      warm_lsp_diagnostics(mission)
    end

    :ok
  end

  def before_advance(_mission, _verdict, _artifact), do: :ok

  # Asks the LSP for diagnostics on the changed files. Side effects:
  # the first request triggers `did_open` (async file read + server
  # analysis), so subsequent reads — notably the next validation
  # phase's `collect_lsp_diagnostics_for_validation/2` — hit a warm
  # cache instead of waiting for ElixirLS's cold-start analysis.
  #
  # Telemetry only; the validation phase decides the verdict.
  defp warm_lsp_diagnostics(mission) do
    files = GiTF.Validation.changed_code_files(mission)

    case GiTF.LSP.collect_errors(mission.sector_id, files) do
      {:ok, []} ->
        :ok

      {:ok, file_errors} ->
        error_count = file_errors |> Enum.map(fn {_, errs} -> length(errs) end) |> Enum.sum()

        Logger.info(
          "Quest #{mission.id}: LSP self-check found #{error_count} error(s) " <>
            "across #{length(file_errors)} file(s) — validation will gate"
        )

        GiTF.Telemetry.emit(
          [:gitf, :implementation, :lsp_errors_detected],
          %{count: error_count, files: length(file_errors)},
          %{mission_id: mission.id}
        )

      {:error, _reason} ->
        :ok
    end
  rescue
    e ->
      Logger.debug(
        "Quest #{mission.id}: LSP self-check failed (#{Exception.message(e)}), skipping"
      )

      :ok
  end
end
