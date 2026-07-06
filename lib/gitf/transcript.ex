defmodule GiTF.Transcript do
  @moduledoc """
  Parses Claude Code JSONL transcript files to extract token usage data.

  Claude Code writes transcript files as newline-delimited JSON (JSONL).
  Each line is an independent JSON object. We look for entries with
  `"type": "result"` that contain a `"usage"` map with token counts.

  This is a pure data-transformation module: file bytes in, structured
  cost data out. No side effects beyond reading the file system.
  """

  @doc """
  Parses a JSONL transcript file into a list of decoded JSON maps.

  Skips lines that fail to parse (e.g. incomplete writes).
  Returns `{:ok, entries}` or `{:error, reason}`.
  """
  @spec parse_file(String.t()) :: {:ok, [map()]} | {:error, term()}
  def parse_file(path) do
    case File.read(path) do
      {:ok, content} ->
        entries = parse_lines(content)
        {:ok, entries}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parses JSONL content from a given byte offset, returning new entries
  and the updated byte offset.

  Used by the TranscriptWatcher for incremental parsing -- only reads
  lines that appeared after the last known position.

  Returns `{entries, new_offset}`.
  """
  @spec parse_from_offset(String.t(), non_neg_integer()) :: {[map()], non_neg_integer()}
  def parse_from_offset(path, offset) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        :file.position(device, offset)
        content = IO.read(device, :eof)
        File.close(device)

        case content do
          :eof ->
            {[], offset}

          data when is_binary(data) ->
            entries = parse_lines(data)
            new_offset = offset + byte_size(data)
            {entries, new_offset}
        end

      {:error, _reason} ->
        {[], offset}
    end
  end

  @doc """
  Extracts cost-relevant entries from parsed transcript data.

  Looks for entries with `"type" => "result"` that contain a
  `"usage"` map. Returns a list of maps with normalized token fields.
  """
  @spec extract_costs([map()]) :: [map()]
  def extract_costs(entries) do
    entries
    |> Enum.filter(&cost_entry?/1)
    |> Enum.map(&normalize_cost_entry/1)
  end

  # -- Private helpers ---------------------------------------------------------

  defp parse_lines(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reduce([], fn line, acc ->
      case Jason.decode(line) do
        {:ok, decoded} -> [decoded | acc]
        {:error, _} -> acc
      end
    end)
    |> Enum.reverse()
  end

  defp cost_entry?(%{"type" => "result", "usage" => %{}}), do: true
  defp cost_entry?(_), do: false

  defp normalize_cost_entry(%{"usage" => usage} = entry) do
    %{
      input_tokens: Map.get(usage, "input_tokens", 0),
      output_tokens: Map.get(usage, "output_tokens", 0),
      cache_read_tokens: cache_read(usage),
      cache_write_tokens: cache_write(usage),
      model: Map.get(entry, "model")
    }
  end

  # The Claude CLI stream-json `result` usage object uses the Anthropic API
  # key names (`cache_read_input_tokens`, `cache_creation_input_tokens`).
  # Earlier code read `cache_read_tokens`/`cache_write_tokens`, which never
  # exist — so cached spend was silently counted as $0. Read the real keys,
  # falling back to the legacy names for any provider that emits them.
  defp cache_read(usage) do
    Map.get(usage, "cache_read_input_tokens") ||
      Map.get(usage, "cache_read_tokens", 0)
  end

  defp cache_write(usage) do
    Map.get(usage, "cache_creation_input_tokens") ||
      Map.get(usage, "cache_write_tokens", 0)
  end
end
