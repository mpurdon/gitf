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

    # Worker.mark_success now treats "ghost reported success but
    # produced zero file changes" as a failure (the `empty_completion?`
    # gate added to catch hallucinated impl ghosts). Tests need the
    # mock to actually touch a file in the worktree (cwd at spawn
    # time) so the auto-commit step records non-zero changes. Caller
    # can opt out with `touch_file: false` for tests that genuinely
    # want the failure path.
    touch_path =
      case Keyword.get(opts, :touch_file, true) do
        false -> nil
        true -> "mock_claude_marker_#{:erlang.unique_integer([:positive])}.txt"
        path when is_binary(path) -> path
      end

    touch_cmd =
      if touch_path do
        "echo \"mock claude run #{:erlang.unique_integer([:positive])}\" > #{touch_path}\n"
      else
        ""
      end

    script = """
    #!/bin/bash
    #{delay_cmd}#{touch_cmd}cat <<'MOCK_OUTPUT'
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

  @doc """
  Returns a realistic multi-turn transcript: an init event, then one
  assistant/tool-result pair per turn, then the terminal result.

  The other builders here emit a flattened shape (`"content"` as a bare
  string) that the real CLI never produces. This one mirrors the real
  `stream-json`: each model call is a nested `message` with a stable `id`
  and its own `usage`, repeated once per content block — which is what
  makes `GiTF.Runtime.CLICallTracker`'s de-duplication necessary rather
  than decorative.

  ## Options

    * `:blocks` - assistant events emitted per model call (default: 2)
    * `:model` - model named in each assistant message
    * `:output_tokens` - output tokens per call (default: 40)
    * `:input_tokens` - input tokens per call (default: 1_000)
  """
  @spec turn_events(pos_integer(), keyword()) :: [map()]
  def turn_events(turns, opts \\ []) do
    session_id =
      Keyword.get(opts, :session_id, "test-session-#{:erlang.unique_integer([:positive])}")

    model = Keyword.get(opts, :model, "claude-sonnet-4-20250514")
    blocks = Keyword.get(opts, :blocks, 2)
    out = Keyword.get(opts, :output_tokens, 40)
    input = Keyword.get(opts, :input_tokens, 1_000)

    init = %{"type" => "system", "subtype" => "init", "session_id" => session_id}

    body =
      Enum.flat_map(1..turns, fn turn ->
        message = %{
          "id" => "msg_test_#{turn}",
          "role" => "assistant",
          "model" => model,
          "content" => [%{"type" => "text", "text" => "turn #{turn}"}],
          "usage" => %{"input_tokens" => input, "output_tokens" => out}
        }

        calls =
          List.duplicate(
            %{"type" => "assistant", "message" => message, "session_id" => session_id},
            blocks
          )

        # Every turn but the last runs a tool and feeds the result back.
        if turn < turns do
          calls ++
            [
              %{
                "type" => "user",
                "message" => %{
                  "role" => "user",
                  "content" => [%{"type" => "tool_result", "tool_use_id" => "toolu_#{turn}"}]
                },
                "session_id" => session_id
              }
            ]
        else
          calls
        end
      end)

    result = %{
      "type" => "result",
      "subtype" => "success",
      "result" => "done",
      "model" => model,
      "usage" => %{
        "input_tokens" => input * turns,
        "output_tokens" => out * turns,
        "cache_read_tokens" => 0,
        "cache_write_tokens" => 0
      },
      "cost_usd" => 0.01
    }

    [init] ++ body ++ [result]
  end

  @doc """
  Writes a mock CLI that emits `turn_events/2` one line at a time, pausing
  before each model call.

  `write_script/2` emits its whole transcript in a single heredoc, which
  arrives as one port message — fine for output assertions, useless for
  latency ones, since every call would appear to take 0ms. Here each
  `echo` is its own write, so the worker sees the turns arrive separately
  and measures a real interval between them.

  ## Options

    * `:call_delay_ms` - pause before each model call's first event
      (default: 150)
    * `:exit_code` - process exit code (default: 0)
    * plus everything `turn_events/2` accepts
  """
  @spec write_turn_script(String.t(), pos_integer(), keyword()) :: {:ok, String.t()}
  def write_turn_script(dir, turns, opts \\ []) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "mock_claude_turns_#{:erlang.unique_integer([:positive])}.sh")

    delay = Keyword.get(opts, :call_delay_ms, 150)
    exit_code = Keyword.get(opts, :exit_code, 0)
    marker = "mock_claude_marker_#{:erlang.unique_integer([:positive])}.txt"

    {lines, _last_id} =
      turns
      |> turn_events(opts)
      |> Enum.map_reduce(nil, fn event, last_id ->
        id = get_in(event, ["message", "id"])
        json = Jason.encode!(event)

        # Pause only before a call's FIRST block: the tracker measures
        # from the tool result back to the finished message, so that is
        # the interval the delay has to land in.
        if event["type"] == "assistant" and id != last_id do
          {"sleep #{delay / 1000}\necho '#{json}'", id}
        else
          {"echo '#{json}'", last_id || id}
        end
      end)

    script = """
    #!/bin/bash
    echo "mock claude turns" > #{marker}
    #{Enum.join(lines, "\n")}
    exit #{exit_code}
    """

    File.write!(path, script)
    File.chmod!(path, 0o755)

    {:ok, path}
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
