defmodule GiTF.LSP.Framing do
  @moduledoc """
  LSP wire-format helpers. Messages on stdio are framed as:

      Content-Length: N\\r\\n
      \\r\\n
      <N bytes of JSON>

  This module is pure: it encodes outgoing payloads and parses incoming
  bytes out of an accumulating buffer. Holding state is the GenServer's
  job (`GiTF.LSP.Client`).
  """

  @doc "Encodes a JSON-RPC payload into a framed iodata blob."
  @spec encode(map()) :: iodata()
  def encode(payload) when is_map(payload) do
    body = Jason.encode!(payload)
    ["Content-Length: ", Integer.to_string(byte_size(body)), "\r\n\r\n", body]
  end

  @doc """
  Parses zero or more framed messages out of `buffer`. Returns
  `{messages, leftover_buffer}` — leftover holds any partial frame at
  the tail.
  """
  @spec parse(binary()) :: {[map()], binary()}
  def parse(buffer) when is_binary(buffer), do: parse_all(buffer, [])

  defp parse_all(buffer, acc) do
    case parse_one(buffer) do
      :incomplete -> {Enum.reverse(acc), buffer}
      {:ok, msg, rest} -> parse_all(rest, [msg | acc])
    end
  end

  defp parse_one(buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [_only] ->
        :incomplete

      [headers, body_with_rest] ->
        case content_length(headers) do
          {:ok, len} when byte_size(body_with_rest) >= len ->
            <<body::binary-size(len), rest::binary>> = body_with_rest

            case Jason.decode(body) do
              {:ok, msg} -> {:ok, msg, rest}
              {:error, _} -> :incomplete
            end

          _ ->
            :incomplete
        end
    end
  end

  defp content_length(headers) do
    headers
    |> :binary.split("\r\n", [:global])
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        ["Content-Length", n] ->
          case Integer.parse(String.trim(n)) do
            {len, _} when len >= 0 -> {:ok, len}
            _ -> nil
          end

        _ ->
          nil
      end
    end) || :error
  end
end
