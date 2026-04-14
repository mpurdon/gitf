defmodule GiTF.Runtime.StreamParser do
  @moduledoc """
  Parses Claude Code's stream-json output format.

  Extracts structured data from the JSON stream emitted by
  `claude --output-format stream-json`, including token usage,
  tool calls, and final results.

  Each line of the stream is a JSON object with a `"type"` field:

  - `"system"` -- system info (model, session ID, etc.)
  - `"assistant"` -- assistant messages with token usage
  - `"result"` -- final result with total usage and cost

  This is a pure data-transformation module: binary in, structured
  maps out. No side effects, no process state.
  """

  # -- Public API ------------------------------------------------------------

  @doc """
  Parses a chunk of stream-json data that may contain multiple lines.

  Returns a list of parsed JSON maps in order. Lines that fail to parse
  are silently dropped -- Claude's stream occasionally includes partial
  lines at chunk boundaries.

  ## Examples

      iex> GiTF.Runtime.StreamParser.parse_chunk(~s({"type":"system","model":"claude-sonnet-4-20250514"}\\n))
      [%{"type" => "system", "model" => "claude-sonnet-4-20250514"}]

  """
  @spec parse_chunk(binary()) :: [map()]
  def parse_chunk(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.reduce([], fn line, acc ->
      case Jason.decode(line) do
        {:ok, parsed} -> [parsed | acc]
        {:error, _} -> acc
      end
    end)
    |> Enum.reverse()
  end

  @doc """
  Extracts cost data from a parsed result entry.

  Returns a map with normalized token counts and cost, or `nil` if the
  entry is not a result type.

  ## Examples

      iex> entry = %{"type" => "result", "usage" => %{"input_tokens" => 100, "output_tokens" => 50}, "model" => "claude-sonnet-4-20250514", "cost_usd" => 0.001}
      iex> GiTF.Runtime.StreamParser.extract_cost(entry)
      %{input_tokens: 100, output_tokens: 50, cache_read_tokens: 0, cache_write_tokens: 0, model: "claude-sonnet-4-20250514", cost_usd: 0.001}

  """
  @spec extract_cost(map()) :: map() | nil
  def extract_cost(%{"type" => "result", "usage" => usage} = entry) do
    %{
      input_tokens: Map.get(usage, "input_tokens", 0),
      output_tokens: Map.get(usage, "output_tokens", 0),
      cache_read_tokens: Map.get(usage, "cache_read_input_tokens", Map.get(usage, "cache_read_tokens", 0)),
      cache_write_tokens: Map.get(usage, "cache_creation_input_tokens", Map.get(usage, "cache_write_tokens", 0)),
      model: Map.get(entry, "model"),
      cost_usd: Map.get(entry, "cost_usd")
    }
  end

  def extract_cost(_), do: nil

  @doc """
  Extracts all cost entries from a list of parsed events.

  Filters out non-result events and returns only the cost maps.
  """
  @spec extract_costs([map()]) :: [map()]
  def extract_costs(events) do
    events
    |> Enum.map(&extract_cost/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Checks if a parsed event indicates the session is complete.

  A result event means Claude has finished processing.

  ## Examples

      iex> GiTF.Runtime.StreamParser.session_complete?(%{"type" => "result"})
      true

      iex> GiTF.Runtime.StreamParser.session_complete?(%{"type" => "assistant"})
      false

  """
  @spec session_complete?(map()) :: boolean()
  def session_complete?(%{"type" => "result"}), do: true
  def session_complete?(_), do: false

  @doc """
  Extracts the session ID from parsed events.

  The session ID appears in the system event at the start of a Claude session.
  Returns the session ID string or nil if not found.

  ## Examples

      iex> events = [%{"type" => "system", "session_id" => "abc123"}]
      iex> GiTF.Runtime.StreamParser.extract_session_id(events)
      "abc123"

  """
  @spec extract_session_id([map()]) :: String.t() | nil
  def extract_session_id(events) do
    Enum.find_value(events, fn
      %{"type" => "system", "session_id" => id} -> id
      _ -> nil
    end)
  end
end
