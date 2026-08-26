defmodule GiTF.Runtime.LLMClient do
  @moduledoc """
  Mockable wrapper around ReqLLM for testability.

  All LLM API calls go through this module so tests can swap in
  `GiTF.Runtime.LLMClient.Mock` via config:

      config :gitf, :llm_client, GiTF.Runtime.LLMClient.Mock

  The default implementation delegates to `ReqLLM.generate_text/3`
  and `ReqLLM.stream_text/3`.
  """

  @type model :: String.t()
  @type messages :: String.t() | ReqLLM.Context.t() | [map()]
  @type opts :: keyword()

  # Implementations own metrics: each impl records its calls via
  # GiTF.Runtime.CallMetrics (Default per HTTP attempt against the routed
  # model, CLIClient per session) — a new impl that skips this produces no
  # latency data and no one will notice until the provider_perf table lies.
  @callback generate_text(model(), messages(), opts()) ::
              {:ok, struct()} | {:error, term()}
  @callback stream_text(model(), messages(), opts()) ::
              {:ok, struct()} | {:error, term()}

  @doc """
  Returns the configured LLM client module.

  With no explicit config, the backend follows the execution mode: `:cli`
  routes EVERYTHING through the claude CLI (`GiTF.Runtime.CLIClient`) —
  when the operator picks a provider, no in-process consumer may silently
  spend on a metered API instead (the post-Max-flip bedrock leak). API
  modes keep the ReqLLM/BedrockDirect default.
  """
  @spec impl() :: module()
  def impl do
    case Application.get_env(:gitf, :llm_client) do
      nil ->
        if GiTF.Runtime.ModelResolver.execution_mode() == :cli do
          GiTF.Runtime.CLIClient
        else
          __MODULE__.Default
        end

      mod ->
        mod
    end
  end

  @doc "Generates text via the configured LLM client."
  @spec generate_text(model(), messages(), opts()) :: {:ok, struct()} | {:error, term()}
  def generate_text(model, messages, opts \\ []) do
    impl().generate_text(model, messages, opts)
  end

  @doc "Streams text via the configured LLM client."
  @spec stream_text(model(), messages(), opts()) :: {:ok, struct()} | {:error, term()}
  def stream_text(model, messages, opts \\ []) do
    impl().stream_text(model, messages, opts)
  end
end

defmodule GiTF.Runtime.LLMClient.Default do
  @moduledoc false
  @behaviour GiTF.Runtime.LLMClient

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolCall

  @impl true
  def generate_text(model, messages, opts) do
    GiTF.Runtime.ProviderCircuit.call(model, fn routed_model ->
      # Timed inside the circuit's call_fn on purpose: this measures ONE
      # attempt against the model that actually served it (the circuit can
      # reroute away from the requested spec), not retries and backoff
      # sleeps. Every non-CLI completion in the factory flows through here,
      # so this one wrap is the whole latency picture.
      started = System.monotonic_time(:millisecond)

      result =
        if is_binary(routed_model) and String.starts_with?(routed_model, "arn:aws:bedrock:") do
          GiTF.Runtime.BedrockDirect.converse(routed_model, messages, opts)
        else
          opts = inject_api_key(routed_model, opts)
          routed_model = GiTF.Runtime.ProviderManager.normalize_model_for_reqllm(routed_model)

          case Keyword.pop(opts, :gemini_cache) do
            {nil, _} ->
              ReqLLM.generate_text(routed_model, messages, opts)

            {cache_name, clean_opts} ->
              run_gemini_cached(routed_model, messages, cache_name, clean_opts)
          end
        end

      record_call(routed_model, started, result)
      result
    end)
  end

  # Nothing here streams, so TTFT is honestly nil rather than a round-trip
  # time wearing a first-token costume. Usage is best-effort off whatever
  # shape the provider returned; a metrics write never fails the call.
  defp record_call(routed_model, started, result) do
    usage = extract_usage(result)

    GiTF.Runtime.CallMetrics.record(%{
      provider: GiTF.Runtime.ProviderCircuit.extract_provider(routed_model),
      model: to_string(routed_model),
      mode: GiTF.Runtime.ModelResolver.execution_mode(),
      kind: :api_call,
      duration_ms: System.monotonic_time(:millisecond) - started,
      ttft_ms: nil,
      streaming: false,
      input_tokens: usage[:input],
      output_tokens: usage[:output],
      outcome: outcome_of(result)
    })
  rescue
    _ -> :ok
  end

  defp outcome_of({:ok, _}), do: :ok
  defp outcome_of({:error, %{__struct__: mod}}), do: mod |> Module.split() |> List.last()
  defp outcome_of({:error, reason}) when is_atom(reason), do: reason
  defp outcome_of(_), do: :error

  defp extract_usage({:ok, response}) do
    u = GiTF.Runtime.Usage.normalize(response)
    %{input: u.input_tokens, output: u.output_tokens}
  end

  defp extract_usage(_), do: %{}

  defp run_gemini_cached(model, messages, cache_name, opts) do
    # Minimal implementation for Gemini Context Caching
    # Assumes messages contains only the user prompt (system prompt is cached)

    # Map model name
    api_model = map_model_name(model)

    key =
      GiTF.Runtime.ProviderManager.api_key_for("google") ||
        raise "Google API key not found in config"

    url =
      "https://generativelanguage.googleapis.com/v1beta/#{api_model}:generateContent?key=#{key}"

    # Extract user content
    # messages is a ReqLLM.Context struct or list
    user_content = extract_user_content(messages)

    body = %{
      "cachedContent" => cache_name,
      "contents" => [
        %{"role" => "user", "parts" => [%{"text" => user_content}]}
      ],
      "generationConfig" => %{
        "temperature" => opts[:temperature],
        "maxOutputTokens" => opts[:max_tokens]
      }
    }

    # Add tools if present
    body =
      if tools = opts[:tools] do
        Map.put(body, "tools", GiTF.Runtime.Gemini.Mapper.map_tools(tools))
      else
        body
      end

    case Req.post(url, json: body) do
      {:ok, %{status: 200, body: resp}} ->
        try do
          response = parse_gemini_response(resp, model)

          # Append assistant response to context so AgentLoop can continue history
          updated_context =
            try do
              ReqLLM.Context.append(messages, response.message)
            rescue
              FunctionClauseError -> messages
              ArgumentError -> messages
            end

          {:ok, %{response | context: updated_context}}
        catch
          {:gemini_blocked, reason} ->
            {:error, "Gemini returned 200 without usable content — #{reason}"}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, "Gemini API #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def stream_text(model, messages, opts) do
    GiTF.Runtime.ProviderCircuit.call(model, fn routed_model ->
      opts = inject_api_key(routed_model, opts)
      routed_model = GiTF.Runtime.ProviderManager.normalize_model_for_reqllm(routed_model)
      ReqLLM.stream_text(routed_model, messages, opts)
    end)
  end

  defp map_model_name(model) do
    clean = String.replace(model, "google:", "")
    if String.starts_with?(clean, "models/"), do: clean, else: "models/#{clean}"
  end

  defp inject_api_key(model, opts) do
    provider = model |> to_string() |> String.split(":") |> List.first()

    opts =
      if Keyword.has_key?(opts, :api_key) do
        opts
      else
        case GiTF.Runtime.ProviderManager.api_key_for(provider) do
          nil -> opts
          key -> Keyword.put(opts, :api_key, key)
        end
      end

    if provider == "ollama" or GiTF.Runtime.ModelResolver.ollama_mode?() do
      base = System.get_env("OLLAMA_BASE_URL") || "http://localhost:11434"

      opts
      |> Keyword.put_new(:base_url, base <> "/v1")
      |> Keyword.put_new(:api_key, "ollama")
    else
      opts
    end
  end

  defp extract_user_content(ctx) do
    # Naive extraction from ReqLLM.Context
    # Assumes the last message is user
    if is_struct(ctx) do
      List.last(ctx.messages).content
    else
      # List of maps
      List.last(ctx).content
    end
  rescue
    _ -> ""
  end

  defp parse_gemini_response(resp, model) do
    candidate = List.first(resp["candidates"] || [])

    # A 200 with no usable candidate is NOT success: safety blocks and
    # MAX_TOKENS truncation returned {:ok, empty} with nil usage, so
    # ghosts silently produced nothing and cost accounting got poisoned.
    block_reason = get_in(resp, ["promptFeedback", "blockReason"])
    finish_reason = candidate && candidate["finishReason"]

    cond do
      is_binary(block_reason) ->
        throw({:gemini_blocked, "prompt blocked: #{block_reason}"})

      candidate == nil ->
        throw({:gemini_blocked, "no candidates in response (finishReason unavailable)"})

      finish_reason in ["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT"] ->
        throw({:gemini_blocked, "candidate blocked: #{finish_reason}"})

      true ->
        :ok
    end

    parts = candidate["content"]["parts"] || []

    # Extract text parts
    text_parts =
      parts
      |> Enum.filter(&Map.has_key?(&1, "text"))
      |> Enum.map_join("\n", & &1["text"])

    # Extract tool calls
    tool_calls =
      parts
      |> Enum.filter(&Map.has_key?(&1, "functionCall"))
      |> Enum.map(fn part ->
        call = part["functionCall"]
        ToolCall.new(nil, call["name"], Jason.encode!(call["args"] || %{}))
      end)

    usage = resp["usageMetadata"] || %{}

    %ReqLLM.Response{
      id: nil,
      context: nil,
      model: model,
      message: %Message{
        role: :assistant,
        content: if(text_parts == "", do: [], else: [ContentPart.text(text_parts)]),
        tool_calls: if(tool_calls == [], do: nil, else: tool_calls)
      },
      usage: %{
        input_tokens: usage["promptTokenCount"],
        output_tokens: usage["candidatesTokenCount"],
        total_tokens: usage["totalTokenCount"]
      }
    }
  end
end
