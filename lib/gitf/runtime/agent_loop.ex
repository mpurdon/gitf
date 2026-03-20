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

    system_prompt = build_system_prompt(Keyword.get(opts, :system_prompt), working_dir)
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    on_progress = Keyword.get(opts, :on_progress)
    temperature = Keyword.get(opts, :temperature)

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
      cache_opts: cache_opts
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

    {:ok, %{
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

    case LLMClient.generate_text(model, messages, generate_opts) do
      {:ok, response} ->
        handle_response(response, messages, model, tools, state)

      {:error, reason} ->
        Logger.error("LLM API error on iteration #{state.iteration}: #{inspect(reason)}")
        {:error, {:api_error, reason}}
    end
  end

  defp handle_response(response, _messages, _model, tools, state) do
    classified = ReqLLM.Response.classify(response)
    usage = response.usage || %{}
    state = accumulate_usage(state, usage)

    # Emit per-response usage so context tracking sees actual window size
    if map_size(usage) > 0 do
      emit_progress(state.on_progress, %{
        type: :response_usage,
        input_tokens: Map.get(usage, :input_tokens, 0),
        output_tokens: Map.get(usage, :output_tokens, 0)
      })
    end

    case classified.type do
      :final_answer ->
        text = classified.text || ""
        result_event = build_result_event(state, :completed)

        emit_progress(state.on_progress, %{
          type: :completed,
          iterations: state.iteration + 1,
          usage: state.total_usage
        })

        {:ok, %{
          text: text,
          events: Enum.reverse([result_event | state.events]),
          usage: state.total_usage,
          iterations: state.iteration + 1,
          status: :completed
        }}

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
        # official method (handles provider-specific message formatting)
        next_context = ReqLLM.Context.execute_and_append_tools(
          response.context, tool_calls, tools
        )

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
    opts = [tools: tools]
    opts = if state.max_tokens, do: Keyword.put(opts, :max_tokens, state.max_tokens), else: opts
    opts = if state.temperature, do: Keyword.put(opts, :temperature, state.temperature), else: opts
    opts = Keyword.merge(opts, Map.get(state, :cache_opts, []))
    opts
  end

  # -- Usage Tracking ----------------------------------------------------------

  defp accumulate_usage(state, nil), do: state

  defp accumulate_usage(state, usage) do
    current = state.total_usage
    input = Map.get(usage, :input_tokens, 0) + Map.get(current, :input_tokens, 0)
    output = Map.get(usage, :output_tokens, 0) + Map.get(current, :output_tokens, 0)
    cost = Map.get(usage, :total_cost, 0) + Map.get(current, :total_cost, 0)

    %{state | total_usage: %{input_tokens: input, output_tokens: output, total_cost: cost}}
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

  defp build_system_prompt(base_prompt, working_dir) do
    agent_content = load_agent_files(working_dir)

    case {base_prompt, agent_content} do
      {nil, ""} -> nil
      {nil, content} -> "## Expert Agent Profiles\n\n" <> content
      {base, ""} -> base
      {base, content} -> base <> "\n\n## Expert Agent Profiles\n\n" <> content
    end
  end

  defp load_agent_files(working_dir) do
    agents_dir = Path.join([working_dir, ".claude", "agents"])

    if File.dir?(agents_dir) do
      agents_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.sort()
      |> Enum.map(fn filename ->
        path = Path.join(agents_dir, filename)
        content = File.read!(path)
        "### #{Path.rootname(filename)}\n\n#{content}"
      end)
      |> Enum.join("\n\n---\n\n")
    else
      ""
    end
  rescue
    _ -> ""
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
