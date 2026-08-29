defmodule GiTF.Phases.Simplify do
  @moduledoc """
  Simplify phase handler.

  `start/3` delegates to the legacy `Orchestrator.dispatch_phase("simplify",
  mission)`. The legacy `start_simplify/1` already handles the
  skip-when-low-complexity shortcut (writes a `{"skipped": true, ...}`
  simplify artifact and returns synchronously), so the workflow's verdict
  sees the artifact and immediately advances to `publish` without needing
  any special "skip simplify" routing in the YAML.

  `verdict/2` mirrors `Orchestrator.check_simplify_complete/1`:

    * `simplify` artifact already present (e.g. the skipped path, or a
      previous tick wrote the synthetic artifact) → `:advance`
    * No simplify ops yet → `:wait`
    * All simplify ops terminal (`done` | `failed`) → `:advance`
      (`before_advance/3` writes the synthetic aggregate artifact)
    * Some still running → `:wait`

  `before_advance(:advance)`, when no artifact is present yet, writes the
  same synthetic `{"agents": [...], "completed_at": ...}` artifact the
  legacy `check_simplify_complete/1` writes so the next phase has
  something to read.
  """

  @behaviour GiTF.Phase

  alias GiTF.Major.Orchestrator

  @impl true
  def start(mission, %GiTF.Workflow.Phase{id: id}, _ctx) do
    Orchestrator.dispatch_phase(id, mission)
  end

  @impl true
  def verdict(_mission, artifact) when is_map(artifact), do: :advance

  def verdict(mission, _artifact) do
    case simplify_ops(mission) do
      [] -> :wait
      ops -> if Enum.all?(ops, &(&1.status in ["done", "failed"])), do: :advance, else: :wait
    end
  end

  @impl true
  def before_advance(mission, :advance, artifact) do
    # The skip path already wrote a synthetic artifact in `start_simplify`;
    # only the all-ops-terminal case needs us to aggregate findings here.
    unless is_map(artifact) do
      agents =
        simplify_ops(mission)
        |> Enum.filter(&(&1.status == "done"))
        |> Enum.map(&op_strategy/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      GiTF.Missions.store_artifact(mission.id, "simplify", %{
        "agents" => agents,
        "completed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })
    end

    :ok
  end

  def before_advance(_mission, _verdict, _artifact), do: :ok

  # -- Helpers ---------------------------------------------------------------

  defp simplify_ops(mission) do
    (Map.get(mission, :ops) || [])
    |> Enum.filter(fn op -> Map.get(op, :phase) == "simplify" end)
  end

  # Delegate to the orchestrator's canonical implementation so legacy
  # simplify ops (no `:strategy` field, name encoded as `[strategy]` in
  # the title) still classify correctly.
  defp op_strategy(op), do: GiTF.Major.ModelPolicy.op_strategy(op)
end
