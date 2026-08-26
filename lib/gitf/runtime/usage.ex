defmodule GiTF.Runtime.Usage do
  @moduledoc """
  One normalizer for every provider's token-usage shape.

  Anthropic reports `input_tokens`, OpenAI `prompt_tokens`/`completion_tokens`,
  Gemini a raw-JSON `"usageMetadata"`. Two normalizers grew independently —
  AgentLoop's (complete) and LLMClient's metrics extractor (Anthropic-only,
  and with a clause order that made its struct case dead: `%{usage: %{}}`
  matches structs too, and bracket-access on a struct without Access raises,
  which a rescue then swallowed along with the whole metrics record). The
  calls it silently dropped were exactly the non-Anthropic providers a
  migration comparison is about. One normalizer, struct-safe, both callers.
  """

  @empty %{input_tokens: 0, output_tokens: 0, total_cost: 0}

  @doc """
  Canonical atom-keyed usage from any provider response shape. Accepts the
  response itself (looks up `:usage` / `"usageMetadata"`) and never raises.
  """
  @spec normalize(term()) :: %{
          required(:input_tokens) => non_neg_integer(),
          required(:output_tokens) => non_neg_integer(),
          required(:total_cost) => number()
        }
  def normalize(%{usage: %{input_tokens: _} = usage}) when not is_struct(usage), do: usage

  def normalize(%{usage: usage}) when is_map(usage) and not is_struct(usage),
    do: normalize_keys(usage)

  def normalize(%{usage: %_{} = usage}), do: normalize_keys(Map.from_struct(usage))

  # Google/Gemini returns raw JSON with a "usageMetadata" string key.
  def normalize(%{"usageMetadata" => meta}) when is_map(meta) do
    %{
      input_tokens: Map.get(meta, "promptTokenCount", 0),
      output_tokens:
        Map.get(meta, "candidatesTokenCount", 0) ||
          max(0, Map.get(meta, "totalTokenCount", 0) - Map.get(meta, "promptTokenCount", 0)),
      total_cost: 0
    }
  end

  def normalize(_), do: @empty

  defp normalize_keys(usage) do
    input =
      Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens") ||
        Map.get(usage, :prompt_tokens) || Map.get(usage, "prompt_tokens") || 0

    output =
      Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens") ||
        Map.get(usage, :completion_tokens) || Map.get(usage, "completion_tokens") ||
        Map.get(usage, :candidates_tokens) || Map.get(usage, "candidates_tokens") || 0

    cost = Map.get(usage, :total_cost) || Map.get(usage, "total_cost") || 0
    %{input_tokens: input, output_tokens: output, total_cost: cost}
  end
end
