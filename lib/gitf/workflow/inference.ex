defmodule GiTF.Workflow.Inference do
  @moduledoc """
  Classifies a mission goal into a workflow template.

  When a mission is created without an explicit `workflow_id` and the
  inference is enabled (`:workflow_inference_enabled` config), this
  module asks a fast LLM to pick from the available templates based on
  the goal text. The classifier returns one of:

      %{
        "workflow" => "bug-fix",
        "confidence" => 0.85,
        "rationale" => "Mentions a stack trace and a 500 error..."
      }

  The mission record gets `workflow_id` set when confidence is at or
  above `:workflow_inference_threshold` (default 0.7). Below threshold,
  the mission falls back to the sector default (or "standard"), and
  the recommendation is stored in `mission.artifacts.workflow_inference`
  for operator visibility on the dashboard.

  Best-effort: any LLM failure leaves the mission alone with the
  default workflow_id.

  ## Why fast LLM, not a regex

  Goals are unstructured prose. A regex catches obvious cases ("fix
  bug X") but misses paraphrases ("the login screen blanks out on
  Safari"). A small classifier with no tools, low max_tokens, and the
  template names as the only valid output is cheap and accurate.
  """

  require Logger

  alias GiTF.Major.PhaseCollector
  alias GiTF.Skills.LLM

  @default_model "anthropic:claude-haiku-4-5-20251001"
  @default_threshold 0.7

  @doc """
  Returns `{:ok, template_name, confidence, rationale}` on a confident
  match, or `:no_match` when below threshold or inference disabled.
  Errors return `:no_match` so callers can fall through cleanly.
  """
  @spec classify(String.t(), keyword()) ::
          {:ok, String.t(), float(), String.t()} | :no_match
  def classify(goal, opts \\ []) when is_binary(goal) do
    if not enabled?() do
      :no_match
    else
      threshold = Keyword.get(opts, :threshold, threshold())
      candidates = available_templates(opts)

      with [_ | _] <- candidates,
           {:ok, payload} <- run_classifier(goal, candidates),
           {:ok, choice} <- pick(payload, candidates, threshold) do
        {:ok, choice.workflow, choice.confidence, choice.rationale}
      else
        _ -> :no_match
      end
    end
  rescue
    e ->
      Logger.warning("Workflow.Inference raised: #{Exception.message(e)}")
      :no_match
  end

  # -- Internals -------------------------------------------------------------

  defp run_classifier(goal, candidates) do
    prompt = build_prompt(goal, candidates)

    case LLM.generate_and_extract(model(), prompt) do
      {:ok, text} -> PhaseCollector.extract_json(text)
      {:error, _} = err -> err
    end
  end

  defp build_prompt(goal, candidates) do
    template_list =
      Enum.map_join(candidates, "\n", fn t ->
        "- #{t.name}: #{String.slice(t.description || "", 0, 140)}"
      end)

    """
    Classify the mission below into ONE of the available workflow
    templates. Reply with ONLY a JSON object:

    {
      "workflow": "<one of the template names>",
      "confidence": <float 0.0-1.0>,
      "rationale": "<one short sentence>"
    }

    Pick "standard" when nothing else clearly fits.

    AVAILABLE TEMPLATES:
    #{template_list}

    MISSION GOAL:
    #{LLM.truncate(goal, 1500)}

    Return JSON only.
    """
  end

  defp pick(%{"workflow" => name} = payload, candidates, threshold) when is_binary(name) do
    confidence = parse_float(payload["confidence"])
    rationale = to_string(payload["rationale"] || "")

    cond do
      not Enum.any?(candidates, &(&1.name == name)) ->
        {:error, :unknown_template}

      confidence < threshold ->
        {:error, :below_threshold}

      true ->
        {:ok, %{workflow: name, confidence: confidence, rationale: rationale}}
    end
  end

  defp pick(_, _, _), do: {:error, :bad_payload}

  defp parse_float(n) when is_float(n), do: n
  defp parse_float(n) when is_integer(n), do: n * 1.0

  defp parse_float(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      _ -> 0.0
    end
  end

  defp parse_float(_), do: 0.0

  defp available_templates(opts) do
    Keyword.get(opts, :templates) || GiTF.Workflow.list()
  end

  @doc "Whether the inference feature is enabled at config time."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:gitf, :workflow_inference_enabled, false) == true

  defp threshold,
    do: Application.get_env(:gitf, :workflow_inference_threshold, @default_threshold)

  defp model, do: Application.get_env(:gitf, :workflow_inference_model, @default_model)
end
