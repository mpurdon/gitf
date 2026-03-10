defmodule Hive.LogFormatter do
  @moduledoc """
  Erlang `:logger` formatter that wraps `:logger_formatter` and applies
  `Hive.Redaction.redact/1` to the formatted output.

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
    event
    |> :logger_formatter.format(config)
    |> IO.iodata_to_binary()
    |> Hive.Redaction.redact()
  end
end
