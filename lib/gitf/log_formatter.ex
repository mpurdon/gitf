defmodule GiTF.LogFormatter do
  @moduledoc """
  Erlang `:logger` formatter that wraps `:logger_formatter` and applies
  `GiTF.Redaction.redact/1` to the formatted output.

  This ensures that secrets (API keys, tokens, passwords) never appear
  in the log file, even if they were passed through Logger calls
  or exception messages.
  """

  @doc """
  Formats a log event and redacts any secrets from the output.

  Conforms to the `:logger` formatter callback signature:
  `format(LogEvent, Config) -> unicode:chardata()`.
  """
  @spec format(:logger.log_event(), :logger.formatter_config()) :: String.t()
  def format(event, config) do
    formatted = :logger_formatter.format(event, config)

    binary =
      case :unicode.characters_to_binary(formatted) do
        bin when is_binary(bin) ->
          bin

        {:incomplete, partial, _} ->
          partial

        {:error, _, _} ->
          try do
            IO.iodata_to_binary(formatted)
          rescue
            _ -> "(log encoding failed)"
          end
      end

    GiTF.Redaction.redact(binary)
  end
end

defmodule GiTF.LogFormatter.JSON do
  @moduledoc """
  Erlang `:logger` formatter emitting one redacted JSON object per line.

  Intended for the stdout handler when the daemon runs under a service
  manager (`GITF_LOG_FORMAT=json`), so journald/CloudWatch/jq can parse
  structured fields instead of scraping text.
  """

  @meta_keys [:ghost_id, :op_id, :mission_id, :sector_id, :component]

  @spec format(:logger.log_event(), :logger.formatter_config()) :: String.t()
  def format(%{level: level, msg: msg, meta: meta}, _config) do
    time_us = Map.get(meta, :time, :os.system_time(:microsecond))

    base = %{
      time: format_time(time_us),
      level: level,
      msg: format_msg(msg, meta)
    }

    base =
      case Map.get(meta, :mfa) do
        {m, f, a} -> Map.put(base, :mfa, "#{inspect(m)}.#{f}/#{a}")
        _ -> base
      end

    extra =
      for key <- @meta_keys, (value = Map.get(meta, key)) != nil, into: %{} do
        {key, to_string_safe(value)}
      end

    json =
      base
      |> Map.merge(extra)
      |> Jason.encode!()

    GiTF.Redaction.redact(json) <> "\n"
  rescue
    # A formatter crash would take the logger handler down with it — degrade
    # to an unstructured line instead.
    _ -> "{\"level\":\"error\",\"msg\":\"(json log formatting failed)\"}\n"
  end

  defp format_time(us) when is_integer(us) do
    us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()
  end

  defp format_time(_), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp format_msg({:string, chardata}, _meta), do: to_string_safe(chardata)

  defp format_msg({:report, report}, %{report_cb: cb}) when is_function(cb, 1) do
    {format, args} = cb.(report)
    :io_lib.format(format, args) |> to_string_safe()
  rescue
    _ -> inspect(report)
  end

  defp format_msg({:report, report}, _meta), do: inspect(report)

  defp format_msg({format, args}, _meta) do
    :io_lib.format(format, args) |> to_string_safe()
  rescue
    _ -> inspect({format, args})
  end

  defp to_string_safe(value) do
    case :unicode.characters_to_binary(value) do
      bin when is_binary(bin) -> bin
      _ -> inspect(value)
    end
  rescue
    _ -> inspect(value)
  end
end
