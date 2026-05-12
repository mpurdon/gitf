defmodule GiTF.Phases.Validation do
  @moduledoc """
  Validation phase handler.

  Verdict reads `overall_verdict` from the artifact (with fallbacks
  `verdict` and nested `overall.verdict` for operator-authored phases).
  `"pass"` / `"passed"` → `:pass`; `"fail"` / `"failed"` → `:fail`;
  anything else → `:inconclusive`.

  Pair with a workflow phase config like:

      - id: validation
        handler: GiTF.Phases.Validation
        on_pass: simplify
        on_fail: implementation
        max_retries: 3
  """

  @behaviour GiTF.Phase

  @impl true
  def start(mission, %GiTF.Workflow.Phase{id: id}, _ctx) do
    GiTF.Major.Orchestrator.dispatch_phase(id, mission)
  end

  @impl true
  def verdict(artifact) when is_map(artifact) do
    case verdict_field(artifact) do
      v when v in ["pass", "passed"] -> :pass
      v when v in ["fail", "failed"] -> :fail
      _ -> :inconclusive
    end
  end

  def verdict(_), do: :inconclusive

  @doc false
  @spec verdict_field(map()) :: String.t()
  def verdict_field(artifact) when is_map(artifact) do
    artifact["overall_verdict"] || artifact[:overall_verdict] ||
      artifact["verdict"] || artifact[:verdict] ||
      get_in(artifact, ["overall", "verdict"]) || ""
  end
end
