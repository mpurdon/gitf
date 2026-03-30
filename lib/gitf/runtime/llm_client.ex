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

  @callback generate_text(model(), messages(), opts()) ::
              {:ok, struct()} | {:error, term()}
  @callback stream_text(model(), messages(), opts()) ::
              {:ok, struct()} | {:error, term()}

  @doc "Returns the configured LLM client module."
  @spec impl() :: module()
  def impl do
    Application.get_env(:gitf, :llm_client, __MODULE__.Default)
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
      if is_binary(routed_model) and String.starts_with?(routed_model, "arn:aws:bedrock:") do
        GiTF.Runtime.BedrockDirect.converse(routed_model, messages, opts)
      else
        routed_model = GiTF.Runtime.ProviderManager.normalize_model_for_reqllm(routed_model)
        opts = inject_api_key(routed_model, opts)

        case Keyword.pop(opts, :gemini_cache) do
          {nil, _} ->
            ReqLLM.generate_text(routed_model, messages, opts)

          {cache_name, clean_opts} ->
            run_gemini_cached(routed_model, messages, cache_name, clean_opts)
        end
      end
    end)
  end

  defp run_gemini_cached(model, messages, cache_name, opts) do
    # Minimal implementation for Gemini Context Caching
    # Assumes messages contains only the user prompt (system prompt is cached)
    
    # Map model name
    api_model = map_model_name(model)
    key = GiTF.Runtime.ProviderManager.api_key_for("google") ||
      raise "Google API key not found in config"
    url = "https://generativelanguage.googleapis.com/v1beta/#{api_model}:generateContent?key=#{key}"
    
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
        
      {:ok, %{status: status, body: body}} ->
        {:error, "Gemini API #{status}: #{inspect(body)}"}
        
      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def stream_text(model, messages, opts) do
    GiTF.Runtime.ProviderCircuit.call(model, fn routed_model ->
      routed_model = GiTF.Runtime.ProviderManager.normalize_model_for_reqllm(routed_model)
      opts = inject_api_key(routed_model, opts)
      ReqLLM.stream_text(routed_model, messages, opts)
    end)
  end
  
  defp map_model_name(model) do
     clean = String.replace(model, "google:", "")
     if String.starts_with?(clean, "models/"), do: clean, else: "models/#{clean}"
  end
  
  defp inject_api_key(model, opts) do
    if Keyword.has_key?(opts, :api_key) do
      opts
    else
      provider = model |> to_string() |> String.split(":") |> List.first()

      case GiTF.Runtime.ProviderManager.api_key_for(provider) do
        nil -> opts
        key -> Keyword.put(opts, :api_key, key)
      end
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
    # Minimal parsing
    candidate = List.first(resp["candidates"] || [])
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
