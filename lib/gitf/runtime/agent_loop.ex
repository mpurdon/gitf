# Implement String.Chars for ReqLLM error structs so to_string()
# works in ReqLLM.Context.execute_and_append_tools error handling.
# These use Splode.Error which provides message/1 but not String.Chars.
for mod <- [
      ReqLLM.Error.Validation.Error,
      ReqLLM.Error.Invalid.Parameter,
      ReqLLM.Error.Invalid.Schema,
      ReqLLM.Error.Unknown.Unknown
    ] do
  defimpl String.Chars, for: mod do
    def to_string(error), do: Exception.message(error)
  end
end

defmodule GiTF.Runtime.AgentLoop do
  @moduledoc """
  Core agentic execution engine.

  Replaces the port-based `spawn_headless` + message accumulation pattern
  with a synchronous loop that calls `LLMClient.generate_text/3`, classifies
  the response, executes tool calls, and continues until a final answer is
  produced or the iteration limit is reached.

  ## Usage

      {:ok, result} = AgentLoop.run("Read test.txt and summarize it", "/path/to/dir",
        model: "anthropic:claude-sonnet-4-6",
        system_prompt: "You are a helpful assistant.",
        tool_set: :standard,
        max_iterations: 50
      )

  ## Result

  Returns `{:ok, result}` where result is a map:

      %{
        text: "The file contains...",
        events: [%{"type" => "system", ...}, ...],
        usage: %{input_tokens: ..., output_tokens: ...},
        iterations: 5,
        status: :completed | :max_iterations
      }

  The `events` list contains synthetic event maps compatible with the
  StreamParser format for cost tracking.
  """

  require Logger

  alias GiTF.Runtime.{LLMClient, Loadout, ModelResolver}

  @default_max_iterations 50
  @default_max_tokens 16_384
  # Thinking-capable models (gemini-2.5-pro, claude opus) include reasoning
  # tokens in the output budget. At 16k, dynamic thinking can eat the whole
  # budget and leave no room for the final text, producing an "empty response"
  # failure. Pro supports up to 65k output tokens; 32k comfortably accommodates
  # thinking + a substantial response.
  @thinking_model_max_tokens 32_768
  @default_receive_timeout 60_000
  # Heartbeat interval while blocked on the LLM HTTP call. The ghost worker
  # kills idle ghosts at `stale_threshold_seconds` (default 120s); without
  # heartbeats, pro-class models with extended thinking can silently exceed
  # that threshold and be misdiagnosed as hung. Must be well under 120s.
  @default_heartbeat_interval_ms 30_000

  # -- Public API --------------------------------------------------------------

  @doc """
  Runs an agentic loop for the given prompt in the specified working directory.

  ## Options

    * `:model` — model spec string (default: resolved "sonnet")
    * `:system_prompt` — system prompt text
    * `:tools` — explicit list of ReqLLM.Tool structs (overrides tool_set)
    * `:tool_set` — `:standard`, `:readonly`, or `:major` (default: `:standard`)
    * `:max_iterations` — iteration limit (default: 50)
    * `:max_tokens` — max tokens per response (default: 16384)
    * `:on_progress` — `fn(event_map) -> :ok` callback for progress updates
    * `:temperature` — sampling temperature
  """
  @spec run(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(prompt, working_dir, opts \\ []) do
    model = resolve_model(opts)
    session_id = generate_session_id()

    tools =
      Keyword.get(opts, :tools) ||
        Loadout.tools(
          working_dir: working_dir,
          tool_set: Keyword.get(opts, :tool_set, :standard),
          include_dynamic: Keyword.get(opts, :include_dynamic, false)
        )

    system_prompt = build_system_prompt(Keyword.get(opts, :system_prompt), working_dir, nil)
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)

    max_tokens =
      Keyword.get(opts, :max_tokens, default_max_tokens_for(model))

    receive_timeout =
      Keyword.get(opts, :receive_timeout, configured_receive_timeout(model))

    on_progress = Keyword.get(opts, :on_progress)
    temperature = Keyword.get(opts, :temperature)

    heartbeat_interval_ms =
      Keyword.get(opts, :heartbeat_interval_ms, @default_heartbeat_interval_ms)

    # Provider-specific options (e.g. `:google_thinking_budget`) — passed
    # verbatim to `LLMClient.generate_text/3`.
    provider_opts = Keyword.get(opts, :provider_opts, [])

    # Build initial context and cache options
    {messages, cache_opts} = prepare_context_and_cache(system_prompt, prompt, model)

    # Emit system event
    events = [
      %{"type" => "system", "model" => model, "session_id" => session_id}
    ]

    emit_progress(on_progress, %{type: :started, model: model, session_id: session_id})

    # Run the loop
    loop(messages, model, tools, %{
      iteration: 0,
      max_iterations: max_iterations,
      max_tokens: max_tokens,
      temperature: temperature,
      events: events,
      total_usage: %{input_tokens: 0, output_tokens: 0, total_cost: 0},
      on_progress: on_progress,
      session_id: session_id,
      last_text: "",
      receive_timeout: receive_timeout,
      cache_opts: cache_opts,
      heartbeat_interval_ms: heartbeat_interval_ms,
      provider_opts: provider_opts
    })
  rescue
    e ->
      Logger.error("AgentLoop crashed: #{Exception.message(e)}")
      {:error, {:agent_loop_crash, Exception.message(e)}}
  end

  # -- Loop --------------------------------------------------------------------

  defp loop(_messages, _model, _tools, %{iteration: i, max_iterations: max} = state)
       when i >= max do
    Logger.warning("AgentLoop hit max iterations (#{max})")

    result_event = build_result_event(state, :max_iterations)

    {:ok,
     %{
       text: state.last_text,
       events: Enum.reverse([result_event | state.events]),
       usage: state.total_usage,
       iterations: state.iteration,
       status: :max_iterations
     }}
  end

  defp loop(messages, model, tools, state) do
    emit_progress(state.on_progress, %{
      type: :iteration,
      iteration: state.iteration,
      max_iterations: state.max_iterations
    })

    generate_opts = build_generate_opts(tools, state)

    case call_llm_with_heartbeat(model, messages, generate_opts, state) do
      {:ok, response} ->
        handle_response(response, messages, model, tools, state)

      {:error, reason} ->
        Logger.error("LLM API error on iteration #{state.iteration}: #{inspect(reason)}")
        {:error, {:api_error, reason}}
    end
  end

  # Runs the blocking LLM call under a Task so `wait_for_llm/3` can emit
  # `:heartbeat` progress events every `heartbeat_interval_ms` — the ghost
  # worker uses these to distinguish "LLM still working" from "worker stuck."
  defp call_llm_with_heartbeat(model, messages, generate_opts, state) do
    start_ms = System.monotonic_time(:millisecond)
    model_str = to_string(model)

    Logger.debug(
      "AgentLoop: calling LLM #{model_str} (iteration #{state.iteration}, " <>
        "heartbeat #{state.heartbeat_interval_ms}ms)"
    )

    GiTF.Telemetry.emit(
      [:gitf, :agent_loop, :llm_call_started],
      %{iteration: state.iteration},
      %{model: model_str}
    )

    task = Task.async(fn -> LLMClient.generate_text(model, messages, generate_opts) end)
    result = wait_for_llm(task, state.on_progress, state.heartbeat_interval_ms)

    outcome =
      case result do
        {:ok, _} -> :ok
        _ -> :error
      end

    GiTF.Telemetry.emit(
      [:gitf, :agent_loop, :llm_call_finished],
      %{elapsed_ms: System.monotonic_time(:millisecond) - start_ms, iteration: state.iteration},
      %{model: model_str, outcome: outcome}
    )

    result
  end

  @doc false
  @spec wait_for_llm(Task.t(), (map() -> any()) | nil, pos_integer()) ::
          {:ok, term()} | {:error, term()}
  def wait_for_llm(task, on_progress, interval_ms) do
    case Task.yield(task, interval_ms) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, {:task_exit, reason}}

      nil ->
        emit_progress(on_progress, %{type: :heartbeat})
        wait_for_llm(task, on_progress, interval_ms)
    end
  end

  # Tool execution with liveness heartbeats. The task is awaited without a
  # deadline of its own — tool runtime policy (wall-clock caps, sandbox
  # timeouts) belongs to the tools and the worker, not this loop; our job is
  # only to keep proving the ghost is alive while a tool runs.
  defp execute_tools_with_heartbeat(context, tool_calls, tools, state) do
    task =
      Task.async(fn ->
        ReqLLM.Context.execute_and_append_tools(context, tool_calls, tools)
      end)

    wait_for_tools(task, state.on_progress, state.heartbeat_interval_ms)
  end

  defp wait_for_tools(task, on_progress, interval_ms) do
    case Task.yield(task, interval_ms) do
      {:ok, next_context} ->
        next_context

      {:exit, reason} ->
        exit(reason)

      nil ->
        emit_progress(on_progress, %{type: :heartbeat})
        wait_for_tools(task, on_progress, interval_ms)
    end
  end

  defp handle_response(response, _messages, _model, tools, state) do
    classified = ReqLLM.Response.classify(response)
    usage = normalize_usage(response)
    state = accumulate_usage(state, usage)

    # Emit per-response usage for context tracking
    input_t = Map.get(usage, :input_tokens, 0)
    output_t = Map.get(usage, :output_tokens, 0)

    if input_t > 0 or output_t > 0 do
      emit_progress(state.on_progress, %{
        type: :response_usage,
        input_tokens: input_t,
        output_tokens: output_t
      })
    end

    case classified.type do
      :final_answer ->
        text = classified.text || ""
        thinking = classified.thinking || ""

        # Guard: an empty final answer is always a failure — callers expect text
        # (JSON payload, prose, etc.). Two shapes show up:
        #
        #   1. Zero tokens + empty text: the HTTP call silently failed.
        #   2. Non-zero tokens + empty text: the model spent its budget on
        #      thinking/reasoning and emitted no user-visible content. Gemini
        #      flash exhibits this when `google_thinking_budget` isn't honored
        #      or the model decides to produce thinking-only output.
        #
        # Both are unusable downstream; the worker's error path will trigger
        # fallback retry instead of storing an empty artifact.
        if text == "" do
          if thinking != "" do
            Logger.error(
              "AgentLoop: empty text with #{byte_size(thinking)} bytes of thinking — " <>
                "model returned thinking-only response (iteration #{state.iteration})"
            )

            {:error, {:api_error, :thinking_only_response}}
          else
            Logger.error(
              "AgentLoop: empty response on iteration #{state.iteration} " <>
                "(usage: #{inspect(state.total_usage)})"
            )

            {:error, {:api_error, :empty_response}}
          end
        else
          result_event = build_result_event(state, :completed)

          emit_progress(state.on_progress, %{
            type: :completed,
            iterations: state.iteration + 1,
            usage: state.total_usage
          })

          {:ok,
           %{
             text: text,
             events: Enum.reverse([result_event | state.events]),
             usage: state.total_usage,
             iterations: state.iteration + 1,
             status: :completed
           }}
        end

      :tool_calls ->
        tool_calls = classified.tool_calls
        state = %{state | last_text: classified.text || state.last_text}

        # Record tool use events
        tool_events =
          Enum.map(tool_calls, fn tc ->
            %{
              "type" => "tool_use",
              "name" => tc.name,
              "input" => tc.arguments
            }
          end)

        state = %{state | events: Enum.reverse(tool_events) ++ state.events}

        # Emit progress for each tool call
        Enum.each(tool_calls, fn tc ->
          emit_progress(state.on_progress, %{
            type: :tool_call,
            tool: tc.name,
            args: tc.arguments,
            iteration: state.iteration
          })
        end)

        # Execute tool calls and append results to context using ReqLLM's
        # official method (handles provider-specific message formatting).
        # Runs under the same heartbeat machinery as LLM calls: a tool that
        # shells out to a long silent build (cargo/ts-rs bindings take
        # minutes on a small box) previously starved the ghost worker's
        # activity watchdog, which killed healthy ghosts at the stale
        # threshold — four identical "No activity" deaths sank msn-8933dc.
        next_context =
          execute_tools_with_heartbeat(response.context, tool_calls, tools, state)

        # Keep the original model spec (with provider prefix) — don't use
        # response.model which may strip the provider prefix (e.g. "gemini-2.5-flash"
        # instead of "google:gemini-2.5-flash")
        loop(next_context, extract_model(state), tools, %{
          state
          | iteration: state.iteration + 1
        })
    end
  end

  # -- Context Building --------------------------------------------------------

  defp prepare_context_and_cache(system_prompt, prompt, model) do
    # Use standard ReqLLM message formatting for all providers.
    # ReqLLM handles provider-specific system prompt formatting internally.
    {build_initial_messages(system_prompt, prompt, model), []}
  end

  defp build_initial_messages(nil, prompt, _model) do
    ReqLLM.Context.new([
      ReqLLM.Context.user(prompt)
    ])
  end

  defp build_initial_messages(system_prompt, prompt, _model) do
    ReqLLM.Context.new([
      ReqLLM.Context.system(system_prompt),
      ReqLLM.Context.user(prompt)
    ])
  end

  # -- Generate Options --------------------------------------------------------

  defp build_generate_opts(tools, state) do
    opts = [tools: tools, receive_timeout: state.receive_timeout]
    opts = if state.max_tokens, do: Keyword.put(opts, :max_tokens, state.max_tokens), else: opts

    opts =
      if state.temperature, do: Keyword.put(opts, :temperature, state.temperature), else: opts

    opts = Keyword.merge(opts, Map.get(state, :cache_opts, []))
    opts = Keyword.merge(opts, Map.get(state, :provider_opts, []))
    opts
  end

  # Thinking-capable models (gemini-2.5-pro, claude opus, etc.) routinely
  # spend more than the flash-sized 90s default on a single response when
  # extended thinking is enabled. 180s is the minimum floor for these models.
  @thinking_model_receive_timeout 180_000

  defp configured_receive_timeout(model) do
    configured = configured_receive_timeout_raw()

    if thinking_tier_model?(model) do
      max(configured, @thinking_model_receive_timeout)
    else
      configured
    end
  end

  defp configured_receive_timeout_raw do
    case GiTF.Config.Provider.get([:llm, :receive_timeout_ms]) do
      val when is_integer(val) and val > 0 -> val
      _ -> @default_receive_timeout
    end
  rescue
    _ -> @default_receive_timeout
  end

  defp thinking_tier_model?(model) when is_binary(model) do
    String.contains?(model, "gemini-2.5-pro") or
      String.contains?(model, "claude-opus")
  end

  defp thinking_tier_model?(_), do: false

  defp default_max_tokens_for(model) do
    if thinking_tier_model?(model), do: @thinking_model_max_tokens, else: @default_max_tokens
  end

  # -- Usage Tracking ----------------------------------------------------------

  # Normalize usage from any provider format into canonical atom-keyed map
  defp normalize_usage(%{usage: %{input_tokens: _} = usage}), do: usage
  defp normalize_usage(%{usage: usage}) when is_map(usage), do: normalize_usage_keys(usage)
  # Google/Gemini returns raw JSON with "usageMetadata" string key
  defp normalize_usage(%{"usageMetadata" => meta}) when is_map(meta) do
    %{
      input_tokens: Map.get(meta, "promptTokenCount", 0),
      output_tokens:
        Map.get(meta, "candidatesTokenCount", 0) ||
          max(0, Map.get(meta, "totalTokenCount", 0) - Map.get(meta, "promptTokenCount", 0)),
      total_cost: 0
    }
  end

  defp normalize_usage(_), do: %{input_tokens: 0, output_tokens: 0, total_cost: 0}

  defp normalize_usage_keys(usage) do
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

  defp accumulate_usage(state, usage) do
    current = state.total_usage
    input = Map.get(usage, :input_tokens, 0) + Map.get(current, :input_tokens, 0)
    output = Map.get(usage, :output_tokens, 0) + Map.get(current, :output_tokens, 0)
    cost = Map.get(usage, :total_cost, 0) + Map.get(current, :total_cost, 0)

    # Cache token breakdown must survive accumulation or the cost recorder
    # prices cached reads as full-rate input.
    cache_read =
      Map.get(usage, :cache_read_tokens, 0) + Map.get(current, :cache_read_tokens, 0)

    cache_write =
      Map.get(usage, :cache_write_tokens, 0) + Map.get(current, :cache_write_tokens, 0)

    %{
      state
      | total_usage: %{
          input_tokens: input,
          output_tokens: output,
          cache_read_tokens: cache_read,
          cache_write_tokens: cache_write,
          total_cost: cost
        }
    }
  end

  # -- Events ------------------------------------------------------------------

  defp build_result_event(state, status) do
    cost = Map.get(state.total_usage, :total_cost, 0)

    %{
      "type" => "result",
      "usage" => state.total_usage,
      "model" => extract_model(state),
      "cost_usd" => cost,
      "session_id" => state.session_id,
      "status" => to_string(status)
    }
  end

  defp extract_model(state) do
    # Find model from the system event
    Enum.find_value(state.events, "unknown", fn
      %{"type" => "system", "model" => m} -> m
      _ -> nil
    end)
  end

  defp emit_progress(nil, _event), do: :ok
  defp emit_progress(callback, event), do: callback.(event)

  # -- System Prompt -----------------------------------------------------------

  # Default system prompt for agent runs. Strong "stop when done" signal
  # because models (especially pro-tier with extended thinking) tend to keep
  # iterating past completion — exploring, re-reading, verifying — which
  # burns wall-clock on trivial edits that were already committed minutes ago.
  @default_system_prompt """
  You are a coding agent with file and shell tools. Complete the task concisely:

  1. Make only the edits the task requires — no speculative refactors.
  2. Commit your changes with `git_commit` when the edit is done.
  3. After committing, reply with ONE SHORT sentence summarizing what you did, then STOP.

  Do not continue exploring, verifying, or polishing after the commit lands. \
  The downstream validation phase will catch real issues — your job ends at commit.
  """

  defp build_system_prompt(base_prompt, _working_dir, _tool_set) do
    # Agent profiles are NOT loaded into the system prompt. Each op already has
    # focused task context (title, description, acceptance criteria) and a
    # generated task-skill file. Loading all .claude/agents/*.md caused massive
    # system prompts that triggered API timeouts on first call.
    case base_prompt do
      nil -> @default_system_prompt
      "" -> @default_system_prompt
      other -> other
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp resolve_model(opts) do
    case Keyword.get(opts, :model) do
      nil -> ModelResolver.resolve("sonnet")
      model -> ModelResolver.resolve(model)
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
