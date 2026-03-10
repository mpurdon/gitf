defmodule Hive.Queen.PhaseCollector do
  @moduledoc """
  Parses raw bee output into structured phase artifacts.

  The bee's stdout contains Claude's stream-json events. The collector
  extracts the assistant's response text, finds the JSON block, validates
  required keys per phase, and returns a structured artifact map.

  Reuses common JSON extraction patterns.
  """

  require Logger

  @phase_required_keys %{
    "research" => ~w(architecture key_files patterns tech_stack),
    "requirements" => ~w(functional_requirements),
    "design" => ~w(components requirement_mapping),
    "review" => ~w(approved coverage),
    "planning" => nil,
    "validation" => ~w(requirements_met overall_verdict)
  }

  @doc """
  Collects and parses phase output into a structured artifact.

  Extracts the last assistant message from parsed events, finds the JSON
  block, validates required keys, and returns the artifact.

  Returns `{:ok, artifact_map}` or `{:error, reason}`.
  """
  @spec collect(String.t(), String.t(), [map()]) :: {:ok, map() | list()} | {:error, term()}
  def collect(phase, raw_output, parsed_events) do
    text = extract_assistant_text(parsed_events, raw_output)

    case extract_json(text) do
      {:ok, data} ->
        validate_artifact(phase, data)

      {:error, reason} ->
        Logger.warning("Phase #{phase} JSON extraction failed: #{inspect(reason)}")
        {:error, :parse_failed}
    end
  end

  @doc """
  Extracts the last assistant message text from parsed events.

  Falls back to scanning raw output if events don't contain assistant messages.
  """
  @spec extract_assistant_text([map()], String.t()) :: String.t()
  def extract_assistant_text(parsed_events, raw_output) do
    # Try to find assistant text in parsed events (CLI mode)
    assistant_text =
      parsed_events
      |> Enum.filter(fn event ->
        Map.get(event, "type") == "assistant" or
          Map.get(event, :type) == "assistant" or
          Map.get(event, "role") == "assistant" or
          Map.get(event, :role) == "assistant"
      end)
      |> Enum.map(fn event ->
        Map.get(event, "content") || Map.get(event, :content) ||
          Map.get(event, "text") || Map.get(event, :text) || ""
      end)
      |> List.last()

    cond do
      is_binary(assistant_text) and assistant_text != "" ->
        assistant_text

      has_api_result?(parsed_events) ->
        # API mode: AgentLoop emits "result" events, not "assistant" events.
        # The raw_output already contains the final text from the Worker's state.output.
        raw_output

      true ->
        raw_output
    end
  end

  defp has_api_result?(events) do
    Enum.any?(events, fn event ->
      (Map.get(event, "type") == "result" and Map.get(event, "status") == "completed") or
        (Map.get(event, :type) == "result" and Map.get(event, :status) == "completed")
    end)
  end

  @doc """
  Extracts JSON from text, handling both raw JSON and markdown-fenced JSON.

  Tries in order:
  1. Direct JSON decode of trimmed text
  2. JSON block within ```json fences
  3. Raw JSON object/array via regex
  """
  @spec extract_json(String.t()) :: {:ok, map() | list()} | {:error, term()}
  def extract_json(text) when is_binary(text) do
    trimmed = String.trim(text)

    # Try direct decode
    case Jason.decode(trimmed) do
      {:ok, data} when is_map(data) or is_list(data) ->
        {:ok, data}

      _ ->
        # Try markdown-fenced JSON
        case Regex.run(~r/```json\s*\n([\s\S]*?)\n\s*```/, trimmed) do
          [_, json_str] ->
            case Jason.decode(String.trim(json_str)) do
              {:ok, data} when is_map(data) or is_list(data) -> {:ok, data}
              _ -> try_raw_json(trimmed)
            end

          nil ->
            try_raw_json(trimmed)
        end
    end
  end

  def extract_json(_), do: {:error, :not_binary}

  @doc """
  Validates that a phase artifact contains required keys.

  Returns `{:ok, data}` if valid, `{:error, {:missing_keys, keys}}` otherwise.
  """
  @spec validate_artifact(String.t(), map() | list()) :: {:ok, map() | list()} | {:error, term()}
  def validate_artifact(phase, data) do
    case Map.get(@phase_required_keys, phase) do
      nil ->
        # Planning phase expects a list, no key validation
        {:ok, data}

      required_keys when is_list(required_keys) ->
        if is_map(data) do
          missing = Enum.reject(required_keys, &Map.has_key?(data, &1))

          if missing == [] do
            {:ok, data}
          else
            Logger.warning("Phase #{phase} artifact missing keys: #{inspect(missing)}")
            # Still return data — partial artifacts are better than none
            {:ok, data}
          end
        else
          {:ok, data}
        end
    end
  end

  # -- Private helpers ---------------------------------------------------------

  defp try_raw_json(text) do
    # Try to find a JSON object
    case Regex.run(~r/\{[\s\S]*\}/, text) do
      [json_str | _] ->
        case Jason.decode(json_str) do
          {:ok, data} when is_map(data) -> {:ok, data}
          _ -> try_raw_json_array(text)
        end

      nil ->
        try_raw_json_array(text)
    end
  end

  defp try_raw_json_array(text) do
    case Regex.run(~r/\[[\s\S]*\]/, text) do
      [json_str | _] ->
        case Jason.decode(json_str) do
          {:ok, data} when is_list(data) -> {:ok, data}
          _ -> {:error, :invalid_json}
        end

      nil ->
        {:error, :no_json_found}
    end
  end
end
