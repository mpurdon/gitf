defmodule GiTF.Phases.Design do
  @moduledoc """
  Design phase handler.

  `start/3` delegates to the legacy `Orchestrator.dispatch_phase("design",
  mission)` which spawns N parallel strategy ghosts (one per
  `minimal`/`normal`/`complex`, gated by triage complexity and `FastPath`)
  and records `mission.design_strategy_count`.

  `verdict/2` mirrors `Orchestrator.check_design_complete/1` against
  `mission.ops`:

    * No design ops yet → `:wait`
    * All design ops terminal (`done` | `failed`):
      * ≥ 1 done → `:advance`
      * all failed → `:terminal_fail` (legacy `fail_quest` with reason
        "All design strategies failed")
    * Some still running → `:wait`

  `before_advance(:advance)` writes a synthetic `design` artifact carrying
  `single_variant` (true when only one strategy completed successfully —
  the legacy "review exists to cross-validate multiple proposals; a
  single-variant design has nothing to pick among" rule), the chosen
  `selected_design`, and the list of done variants. When `single_variant`,
  it also calls `Orchestrator.promote_selected_design/2` so the planning
  phase sees the chosen variant on the canonical `"design"` artifact key.

  Pair with a workflow phase config like:

      - id: design
        handler: GiTF.Phases.Design
        strategies: [minimal, normal, complex]
        next:
          - when: "artifact.single_variant == true"
            then: planning     # skip review for a single-variant design
          - else: review

  ## Not yet captured

  Parallel-strategy *execution* and the design tournament (audit gap #7)
  still live in the legacy `start_design/1` body — `Phases.Design` is
  just the seam for completion + variant selection. Replacing parallel
  spawning with a real tournament is its own feature.
  """

  @behaviour GiTF.Phase

  require Logger

  alias GiTF.Major.Orchestrator

  @impl true
  def start(mission, %GiTF.Workflow.Phase{id: id}, _ctx) do
    Orchestrator.dispatch_phase(id, mission)
  end

  @impl true
  def verdict(mission, _artifact) do
    case design_ops(mission) do
      [] ->
        :wait

      ops ->
        terminal = Enum.filter(ops, &(&1.status in ["done", "failed"]))

        if length(terminal) == length(ops) do
          done = Enum.filter(ops, &(&1.status == "done"))
          if done == [], do: :terminal_fail, else: :advance
        else
          :wait
        end
    end
  end

  @impl true
  def before_advance(mission, :advance, _artifact) do
    done_variants =
      design_ops(mission)
      |> Enum.filter(&(&1.status == "done"))
      |> Enum.map(&op_strategy/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    single_variant? = length(done_variants) <= 1
    selected = List.first(done_variants) || "minimal"

    artifact = %{
      "variants" => done_variants,
      "selected_design" => selected,
      "single_variant" => single_variant?,
      "completed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    GiTF.Missions.store_artifact(mission.id, "design", artifact)

    if single_variant? do
      Orchestrator.promote_selected_design(mission.id, %{"selected_design" => selected})
    end

    :ok
  end

  def before_advance(_mission, _verdict, _artifact), do: :ok

  @impl true
  def terminal(mission, :retries_exhausted, _artifact) do
    Logger.warning("Quest #{mission.id}: all design strategies failed")
    GiTF.Missions.fail_quest(mission.id, "All design strategies failed")
    :ok
  end

  def terminal(_mission, _kind, _artifact), do: :ok

  # -- Helpers ---------------------------------------------------------------

  defp design_ops(mission) do
    (Map.get(mission, :ops) || [])
    |> Enum.filter(fn op ->
      Map.get(op, :phase_job) == true and Map.get(op, :phase) == "design"
    end)
  end

  # Delegate to the orchestrator's canonical implementation which falls
  # back to the legacy `[strategy]` title regex for pre-migration ops —
  # without that fallback, those ops yield `nil` strategy and get filtered
  # out, falsely marking the design as single-variant.
  defp op_strategy(op), do: Orchestrator.op_strategy(op)
end
