defmodule GiTF.Phases.Review do
  @moduledoc """
  Review phase handler.

  Owns:

    * **Verdict** — read `review.approved` boolean from the artifact.
    * **Side effect** — when advancing to planning (whether via `:pass`
      or via `on_exhausted: :advance` after exceeding redesign budget),
      promote the review's `selected_design` onto the canonical
      `"design"` artifact key so the planning phase reads the chosen
      variant.

  Maps directly onto the legacy `Major.Orchestrator.handle_review_result/1`
  semantic. The legacy path stays in place for `workflow_id == "standard"`
  missions; this module owns review behaviour for any non-standard
  workflow.

  Pair with a workflow phase config like:

      - id: review
        handler: GiTF.Phases.Review
        on_pass: planning
        on_fail: design
        max_retries: 2
        on_exhausted: advance   # give up but proceed to planning
  """

  @behaviour GiTF.Phase

  @impl true
  def start(mission, %GiTF.Workflow.Phase{id: id}, _ctx) do
    GiTF.Major.Orchestrator.dispatch_phase(id, mission)
  end

  @impl true
  def verdict(%{"approved" => true}), do: :pass
  def verdict(%{"approved" => false}), do: :fail
  def verdict(_), do: :inconclusive

  @impl true
  def before_advance(mission, verdict, artifact)
      when verdict in [:pass, :advance] and is_map(artifact) do
    GiTF.Major.Orchestrator.promote_selected_design(mission.id, artifact)
    :ok
  end

  # A rejection is only worth another redesign round if it says something
  # NEW. Record a fingerprint of each rejection so `max_retries/2` can tell
  # "the review found a further problem" from "the review repeated itself
  # at a fresh design" — the latter burns a full design fan-out (~5 min and
  # three ghosts) to relitigate a settled objection.
  def before_advance(mission, :fail, artifact) when is_map(artifact) do
    record_rejection(mission, artifact)
    :ok
  end

  def before_advance(_mission, _verdict, _artifact), do: :ok

  @doc false
  @spec rejection_fingerprint(map()) :: String.t()
  def rejection_fingerprint(artifact) do
    [
      artifact["summary"],
      artifact["reason"],
      artifact["feedback"],
      artifact["gaps"]
    ]
    |> Enum.filter(&(is_binary(&1) or is_list(&1)))
    |> Enum.map(&to_string_flat/1)
    |> Enum.join(" ")
    |> String.downcase()
    # Normalise incidentals so "same objection, different words for the
    # variant it looked at" still counts as a repeat.
    |> String.replace(~r/[^a-z ]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.sort()
    |> Enum.uniq()
    |> Enum.join(" ")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp to_string_flat(v) when is_list(v), do: Enum.map_join(v, " ", &to_string_flat/1)
  defp to_string_flat(v) when is_binary(v), do: v
  defp to_string_flat(v), do: inspect(v)

  defp record_rejection(mission, artifact) do
    fp = rejection_fingerprint(artifact)

    GiTF.Archive.update(:missions, mission.id, fn m ->
      history = get_in(m, [Access.key(:artifacts, %{}), "review_rejections"]) || []
      artifacts = Map.get(m, :artifacts, %{})
      Map.put(m, :artifacts, Map.put(artifacts, "review_rejections", Enum.take([fp | history], 5)))
    end)
  rescue
    _ -> :ok
  end

  @doc false
  # True when the last two rejections said the same thing — another
  # redesign round would relitigate, not progress.
  @spec repeating?(map()) :: boolean()
  def repeating?(mission) do
    case get_in(Map.get(mission, :artifacts, %{}), ["review_rejections"]) do
      [a, b | _] -> a == b
      _ -> false
    end
  end

  # The YAML's `max_retries: 2` is a template default; if the mission's
  # sector has a high-confidence intelligence profile recommending a
  # different redesign budget, honour that. Mirrors the legacy
  # `reject_design/2` / `handle_review_result/1` policy so operator
  # rejections and ghost-driven review failures share the same ceiling.
  @impl true
  def max_retries(mission, _phase_config) do
    if repeating?(mission) do
      # Budget spent: the review is repeating an objection the last
      # redesign already answered (or failed to), so advance with the best
      # design rather than paying for another identical debate.
      0
    else
      GiTF.Major.Orchestrator.max_redesign_for(Map.get(mission, :sector_id))
    end
  end
end
