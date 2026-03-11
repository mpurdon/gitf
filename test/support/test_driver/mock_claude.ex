defmodule GiTF.TestDriver.MockClaude do
  @moduledoc """
  Generates executable bash scripts that simulate Claude Code output.

  Scripts emit valid stream-json matching `GiTF.Runtime.StreamParser.parse_chunk/1`
  format, with configurable exit codes, output content, and delays.

  The mock scripts are used via the `claude_executable` option in `GiTF.Ghost.Worker`
  to test the full Worker -> Port -> StreamParser pipeline without calling real Claude.
  """

  @doc """
  Writes an executable bash script to the given directory and returns its path.

  ## Options

    * `:exit_code` - process exit code (default: 0)
    * `:delay_ms` - sleep duration in ms before exiting (default: 0)
    * `:output` - raw string output to emit (overrides structured output)
    * `:events` - list of stream-json event maps to emit
    * `:input_tokens` - token count for result event (default: 100)
    * `:output_tokens` - token count for result event (default: 50)
    * `:cost_usd` - cost for result event (default: 0.001)
    * `:model` - model name for result event (default: "claude-sonnet-4-20250514")
    * `:session_id` - session ID for system event (default: "test-session-xxx")
    * `:assistant_text` - text for assistant message (default: "Task completed successfully.")

  """
  @spec write_script(String.t(), keyword()) :: {:ok, String.t()}
  def write_script(dir, opts \\ []) do
    File.mkdir_p!(dir)

    name = "mock_claude_#{:erlang.unique_integer([:positive])}.sh"
    path = Path.join(dir, name)

    exit_code = Keyword.get(opts, :exit_code, 0)
    delay_ms = Keyword.get(opts, :delay_ms, 0)
    output = Keyword.get(opts, :output)

    body =
      if output do
        output
      else
        events = Keyword.get(opts, :events) || build_default_events(opts)
        events |> Enum.map(&Jason.encode!/1) |> Enum.join("\n")
      end

    delay_cmd =
      if delay_ms > 0 do
        seconds = delay_ms / 1000
        "sleep #{seconds}\n"
      else
        ""
      end

    script = """
    #!/bin/bash
    #{delay_cmd}cat <<'MOCK_OUTPUT'
    #{body}
    MOCK_OUTPUT
    exit #{exit_code}
    """

    File.write!(path, script)
    File.chmod!(path, 0o755)

    {:ok, path}
  end

  @doc "Returns default events for a successful Claude session."
  @spec default_success_events(keyword()) :: [map()]
  def default_success_events(opts \\ []) do
    build_default_events(opts)
  end

  @doc "Returns events for a failed Claude session (non-zero exit, no result)."
  @spec failure_events(keyword()) :: [map()]
  def failure_events(opts \\ []) do
    session_id =
      Keyword.get(opts, :session_id, "test-session-#{:erlang.unique_integer([:positive])}")

    model = Keyword.get(opts, :model, "claude-sonnet-4-20250514")

    [
      %{"type" => "system", "session_id" => session_id, "model" => model},
      %{"type" => "assistant", "content" => "I encountered an error and cannot proceed."}
    ]
  end

  @doc "Returns events with specific cost data for cost-tracking tests."
  @spec events_with_costs(non_neg_integer(), non_neg_integer(), float(), keyword()) :: [map()]
  def events_with_costs(input_tokens, output_tokens, cost_usd, opts \\ []) do
    session_id =
      Keyword.get(opts, :session_id, "test-session-#{:erlang.unique_integer([:positive])}")

    model = Keyword.get(opts, :model, "claude-sonnet-4-20250514")
    cache_read = Keyword.get(opts, :cache_read_tokens, 0)
    cache_write = Keyword.get(opts, :cache_write_tokens, 0)

    [
      %{"type" => "system", "session_id" => session_id, "model" => model},
      %{"type" => "assistant", "content" => "Working on the task..."},
      %{
        "type" => "result",
        "model" => model,
        "usage" => %{
          "input_tokens" => input_tokens,
          "output_tokens" => output_tokens,
          "cache_read_tokens" => cache_read,
          "cache_write_tokens" => cache_write
        },
        "cost_usd" => cost_usd
      }
    ]
  end

  # -- Private -----------------------------------------------------------------

  defp build_default_events(opts) do
    session_id =
      Keyword.get(opts, :session_id, "test-session-#{:erlang.unique_integer([:positive])}")

    model = Keyword.get(opts, :model, "claude-sonnet-4-20250514")
    input_tokens = Keyword.get(opts, :input_tokens, 100)
    output_tokens = Keyword.get(opts, :output_tokens, 50)
    cost_usd = Keyword.get(opts, :cost_usd, 0.001)
    text = Keyword.get(opts, :assistant_text, "Task completed successfully.")

    [
      %{"type" => "system", "session_id" => session_id, "model" => model},
      %{"type" => "assistant", "content" => text},
      %{
        "type" => "result",
        "model" => model,
        "usage" => %{
          "input_tokens" => input_tokens,
          "output_tokens" => output_tokens,
          "cache_read_tokens" => 0,
          "cache_write_tokens" => 0
        },
        "cost_usd" => cost_usd
      }
    ]
  end
end
