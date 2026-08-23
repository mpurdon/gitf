defmodule GiTF.Major.DesignReport do
  @moduledoc """
  Synthesises the design phase's competing strategies into a decision brief.

  The design page can already show *what* each strategy proposed and *which*
  one the review picked. What it cannot show is the argument: whether the
  strategies genuinely forked or described the same change at different
  lengths, what each one's judgement looked like, and what overriding the
  pick would actually cost. That reading is what an operator does by hand
  before agreeing with a plan, and it is a synthesis job, not a rendering
  job — so it takes one LLM call over artifacts the mission already has.

  Generated on demand rather than at the end of every design phase: most
  missions are never questioned, and a report nobody reads is a call nobody
  should pay for. `generate/1` is idempotent in effect but not cached —
  asking again re-synthesises against the current artifacts.

  In CLI execution mode this routes through the claude CLI like every other
  in-process consumer, so the marginal cost is the same as a phase ghost's.
  """

  require Logger

  alias GiTF.Major.PhaseCollector
  alias GiTF.Missions
  alias GiTF.Runtime.ModelResolver
  alias GiTF.Skills.LLM

  @artifact_key "design_report"
  @strategies ["minimal", "normal", "complex"]

  # Each design runs to a few KB of JSON; three of them plus requirements and
  # the review comfortably fit a single call, but a pathological artifact
  # should not blow the request up.
  @per_artifact_bytes 12_000

  @doc "Returns the stored report, or nil when one has never been generated."
  @spec get(String.t()) :: map() | nil
  def get(mission_id), do: Missions.get_artifact(mission_id, @artifact_key)

  @doc """
  Synthesises and stores a decision brief for the mission's design phase.

  Returns `{:ok, report}`, or `{:error, :no_designs}` when the design phase
  has not produced anything to compare yet.
  """
  @spec generate(String.t()) :: {:ok, map()} | {:error, term()}
  def generate(mission_id) do
    designs =
      for s <- @strategies,
          artifact = Missions.get_artifact(mission_id, "design_#{s}"),
          is_map(artifact),
          do: {s, artifact}

    if designs == [] do
      {:error, :no_designs}
    else
      with {:ok, mission} <- Missions.get(mission_id),
           {:ok, text} <- call_model(mission, designs),
           {:ok, report} <- PhaseCollector.extract_json(text),
           true <- is_map(report) || {:error, :unexpected_shape} do
        report = Map.put(report, "generated_from", Enum.map(designs, &elem(&1, 0)))
        Missions.store_artifact(mission_id, @artifact_key, report)
        {:ok, report}
      else
        false -> {:error, :unexpected_shape}
        {:error, _} = err -> err
        other -> {:error, other}
      end
    end
  end

  defp call_model(mission, designs) do
    model = ModelResolver.resolve("thinking")

    case LLM.generate_and_extract(model, prompt(mission, designs)) do
      {:ok, ""} ->
        {:error, :empty_completion}

      {:ok, text} ->
        {:ok, text}

      {:error, reason} = err ->
        Logger.warning("Design report generation failed for #{mission.id}: #{inspect(reason)}")
        err
    end
  end

  defp prompt(mission, designs) do
    requirements = encode(Missions.get_artifact(mission.id, "requirements"))
    review = encode(Missions.get_artifact(mission.id, "review"))

    design_sections =
      Enum.map_join(designs, "\n\n", fn {strategy, artifact} ->
        "### Strategy: #{strategy}\n\n```json\n#{encode(artifact)}\n```"
      end)

    """
    # Design Decision Brief

    You are writing a brief for the engineer who has to decide whether they
    agree with the design the review selected. They can already see the raw
    artifacts. What they cannot see is the argument, so give them that.

    Be concrete and specific to this codebase. Name files, functions, and
    mechanisms. Do not restate requirement lists back at them. If the
    strategies converged on the same approach, say so plainly rather than
    manufacturing a contrast — that is itself the most useful finding,
    because it means the choice was about rigor, not architecture.

    **Goal**: #{mission.goal}

    ## Requirements

    ```json
    #{requirements}
    ```

    ## Competing designs

    #{design_sections}

    ## Review verdict

    ```json
    #{review}
    ```

    ## Output Format

    Output ONLY a JSON object in a ```json fence:

    ```json
    {
      "headline": "One sentence naming what the choice actually was.",
      "convergence": "Where the designs agreed and whether there was a real fork. 2-4 sentences.",
      "designs": [
        {
          "strategy": "minimal",
          "character": "One sentence on this design's disposition.",
          "notable": ["What it saw that mattered"],
          "missed": ["What it failed to anticipate that another design caught"]
        }
      ],
      "decision": "Why the selected design won, and what picking a different one would have cost. 2-4 sentences.",
      "watch_items": [
        {
          "concern": "Something that survived into the plan and is worth checking during or after implementation.",
          "why_it_matters": "The concrete failure it leads to."
        }
      ]
    }
    ```

    Include one `designs` entry per strategy above, in the same order. Use an
    empty `missed` list when a design missed nothing. Keep `watch_items` to
    the few that would actually change someone's mind about merging.
    """
  end

  defp encode(nil), do: "{}"

  defp encode(artifact) do
    artifact
    |> Jason.encode!()
    |> LLM.truncate(@per_artifact_bytes)
  end
end
