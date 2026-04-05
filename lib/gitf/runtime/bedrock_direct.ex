defmodule GiTF.Runtime.BedrockDirect do
  @moduledoc """
  Direct Bedrock Converse API client for ARN inference profiles.

  ReqLLM's `get_model_family` raises on ARN strings because they don't
  follow the `provider.model` dot format. This module bypasses ReqLLM
  entirely and calls the Converse API using Req + AWSAuth SigV4 signing.

  Used automatically by `LLMClient.Default` when the model is an ARN.
  """

  require Logger

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolCall

  @doc """
  Calls the Bedrock Converse API with an ARN inference profile.

  Accepts ReqLLM.Context or a list of message maps. Returns
  `{:ok, %ReqLLM.Response{}}` or `{:error, reason}` for compatibility
  with the rest of the ghost pipeline.
  """
  @spec converse(String.t(), term(), keyword()) :: {:ok, struct()} | {:error, term()}
  def converse(arn, messages, opts \\ []) do
    region = parse_arn_region(arn) || "us-east-1"
    GiTF.Runtime.ProviderManager.ensure_aws_credentials()
    System.put_env("AWS_REGION", region)

    creds = build_aws_credentials(region)
    host = "bedrock-runtime.#{region}.amazonaws.com"
    # Pre-encode the ARN for the URL path. AWS SigV4 then encodes the canonical
    # path again (double-encoding), which is what Bedrock expects.
    encoded_arn = URI.encode(arn, &URI.char_unreserved?/1)
    url = "https://#{host}/model/#{encoded_arn}/converse"

    body = build_converse_body(messages, opts)
    json_body = Jason.encode!(body)

    # Use AWSAuth.Req plugin for signing. This integrates signing directly
    # into Req's request pipeline, ensuring the exact headers/body that get
    # signed are the same ones that get sent on the wire. Manual signing
    # (sign first, then create Req request) can diverge if Req's default
    # steps modify headers between construction and sending.
    req =
      Req.new(
        url: url,
        method: :post,
        body: json_body,
        headers: %{"content-type" => "application/json"},
        receive_timeout: opts[:receive_timeout] || 90_000,
        # Disable Req's default compressed/accept-encoding step to keep
        # the header set minimal and deterministic for SigV4 signing.
        compressed: false
      )
      |> AWSAuth.Req.attach(credentials: creds, service: "bedrock", region: region)

    case Req.request(req) do
      {:ok, %{status: 200, body: resp}} ->
        response = parse_converse_response(resp, arn, messages)

        # Verify we got actual content — a 200 with empty output means something went wrong
        output_tokens = get_in(response.usage, [:output_tokens]) || 0
        text = ReqLLM.Response.text(response) || ""

        if output_tokens == 0 and text == "" do
          Logger.warning(
            "BedrockDirect: got 200 but empty response body: #{inspect(resp, limit: 500)}"
          )

          {:error, "Bedrock returned empty response"}
        else
          {:ok, response}
        end

      {:ok, %{status: status, body: %{"message" => msg}}} ->
        {:error, "Bedrock #{status}: #{msg}"}

      {:ok, %{status: status, body: body}} when is_binary(body) ->
        {:error, "Bedrock #{status}: #{String.slice(body, 0, 300)}"}

      {:ok, %{status: status}} ->
        {:error, "Bedrock #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # -- Body Building -----------------------------------------------------------

  defp build_converse_body(messages, opts) do
    {system_parts, user_messages} = extract_messages(messages)

    body = %{"messages" => user_messages}

    body =
      if system_parts != [] do
        Map.put(body, "system", system_parts)
      else
        body
      end

    # Inference config
    inference = %{}

    inference =
      if opts[:max_tokens],
        do: Map.put(inference, "maxTokens", opts[:max_tokens]),
        else: inference

    inference =
      if opts[:temperature],
        do: Map.put(inference, "temperature", opts[:temperature]),
        else: inference

    body = if inference != %{}, do: Map.put(body, "inferenceConfig", inference), else: body

    # Tools
    body =
      if opts[:tools] && opts[:tools] != [] do
        Map.put(body, "toolConfig", %{"tools" => format_tools(opts[:tools])})
      else
        body
      end

    body
  end

  # Extract messages from ReqLLM.Context or plain list
  defp extract_messages(%{messages: messages}) when is_list(messages) do
    extract_messages(messages)
  end

  defp extract_messages(messages) when is_list(messages) do
    {system_msgs, other} =
      Enum.split_with(messages, fn msg ->
        get_role(msg) in [:system, "system"]
      end)

    system_parts =
      Enum.map(system_msgs, fn msg ->
        %{"text" => content_to_string(msg)}
      end)

    # Convert each message to a {role, parts} tuple
    raw_messages =
      Enum.map(other, fn msg ->
        role = get_role(msg)
        tool_calls = get_field(msg, :tool_calls) || []
        tool_call_id = get_field(msg, :tool_call_id)

        bedrock_role =
          case role do
            r when r in [:assistant, "assistant"] -> "assistant"
            _ -> "user"
          end

        parts =
          cond do
            role in [:tool, "tool"] and tool_call_id ->
              [
                %{
                  "toolResult" => %{
                    "toolUseId" => tool_call_id,
                    "content" => [%{"text" => content_to_string(msg)}]
                  }
                }
              ]

            tool_calls != [] and tool_calls != nil ->
              text = content_to_string(msg)
              text_parts = if text != "", do: [%{"text" => text}], else: []
              tool_parts = Enum.map(tool_calls, &format_tool_call/1)
              text_parts ++ tool_parts

            true ->
              [%{"text" => content_to_string(msg)}]
          end

        {bedrock_role, parts}
      end)

    # Bedrock requires all tool results for a turn in a single user message.
    # Merge consecutive messages with the same role.
    user_messages =
      raw_messages
      |> Enum.chunk_while(
        nil,
        fn
          {role, parts}, nil ->
            {:cont, {role, parts}}

          {role, parts}, {role, acc_parts} ->
            {:cont, {role, acc_parts ++ parts}}

          {role, parts}, acc ->
            {:cont, %{"role" => elem(acc, 0), "content" => elem(acc, 1)}, {role, parts}}
        end,
        fn
          nil -> {:cont, nil}
          acc -> {:cont, %{"role" => elem(acc, 0), "content" => elem(acc, 1)}, nil}
        end
      )
      |> Enum.reject(&is_nil/1)

    {system_parts, user_messages}
  end

  defp extract_messages(_), do: {[], []}

  # Get role from Message struct or plain map
  defp get_role(%{role: role}), do: role
  defp get_role(%{"role" => role}), do: role
  defp get_role(_), do: :user

  # Get a field from struct or map
  defp get_field(msg, key) do
    Map.get(msg, key) || Map.get(msg, to_string(key))
  end

  # Convert content (string, ContentPart list, or anything) to a plain string
  defp content_to_string(%{content: content}), do: normalize_content(content)
  defp content_to_string(%{"content" => content}), do: normalize_content(content)
  defp content_to_string(other), do: to_string(other)

  defp normalize_content(content) when is_binary(content), do: content

  defp normalize_content(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{type: :text, text: text} -> text || ""
      %{text: text} when is_binary(text) -> text
      %{"text" => text} when is_binary(text) -> text
      part when is_binary(part) -> part
      _ -> ""
    end)
    |> Enum.join("\n")
  end

  defp normalize_content(nil), do: ""
  defp normalize_content(other), do: to_string(other)

  defp format_tool_call(%ReqLLM.ToolCall{id: id, function: %{name: name, arguments: args}}) do
    input = if is_binary(args), do: Jason.decode!(args), else: args || %{}
    %{"toolUse" => %{"toolUseId" => id, "name" => name, "input" => input}}
  end

  defp format_tool_call(tc) do
    name = get_field(tc, :name) || get_in(tc, [:function, :name]) || ""
    args = get_field(tc, :arguments) || get_in(tc, [:function, :arguments]) || %{}
    input = if is_binary(args), do: Jason.decode!(args), else: args

    %{
      "toolUse" => %{
        "toolUseId" => get_field(tc, :id) || random_id(),
        "name" => to_string(name),
        "input" => input
      }
    }
  end

  defp format_tools(tools) do
    Enum.map(tools, &ReqLLM.Tool.to_schema(&1, :amazon_bedrock_converse))
  end

  # -- Response Parsing --------------------------------------------------------

  defp parse_converse_response(resp, model, messages) do
    output = resp["output"] || %{}
    message = output["message"] || %{}
    content_parts = message["content"] || []
    usage = resp["usage"] || %{}

    # Extract text
    text =
      content_parts
      |> Enum.filter(&Map.has_key?(&1, "text"))
      |> Enum.map_join("\n", & &1["text"])

    # Extract tool calls
    tool_calls =
      content_parts
      |> Enum.filter(&Map.has_key?(&1, "toolUse"))
      |> Enum.map(fn part ->
        tc = part["toolUse"]
        ToolCall.new(tc["toolUseId"], tc["name"], Jason.encode!(tc["input"] || %{}))
      end)

    # Build context for conversation continuity.
    # IMPORTANT: The assistant message must include tool_calls so that
    # extract_messages can produce matching toolUse blocks on the next
    # iteration. Without them Bedrock rejects the request because it
    # sees toolResult blocks without preceding toolUse blocks.
    updated_context =
      try do
        assistant_msg =
          if tool_calls != [] do
            ReqLLM.Context.assistant(text, tool_calls: tool_calls)
          else
            ReqLLM.Context.assistant(text)
          end

        ReqLLM.Context.append(messages, assistant_msg)
      rescue
        _ -> messages
      end

    %ReqLLM.Response{
      id: nil,
      context: updated_context,
      model: model,
      message: %Message{
        role: :assistant,
        content: if(text == "", do: [], else: [ContentPart.text(text)]),
        tool_calls: if(tool_calls == [], do: nil, else: tool_calls)
      },
      usage: %{
        input_tokens: usage["inputTokens"] || 0,
        output_tokens: usage["outputTokens"] || 0,
        total_tokens: (usage["inputTokens"] || 0) + (usage["outputTokens"] || 0)
      }
    }
  end

  # -- AWS Helpers -------------------------------------------------------------

  defp build_aws_credentials(region) do
    access_key = System.get_env("AWS_ACCESS_KEY_ID")
    secret_key = System.get_env("AWS_SECRET_ACCESS_KEY")
    session_token = System.get_env("AWS_SESSION_TOKEN")

    if access_key && secret_key do
      creds = %{
        access_key_id: access_key,
        secret_access_key: secret_key,
        region: region
      }

      creds = if session_token, do: Map.put(creds, :session_token, session_token), else: creds
      AWSAuth.Credentials.from_map(creds)
    else
      raise "AWS credentials not available. Run ensure_aws_credentials first."
    end
  end

  defp parse_arn_region(arn) do
    case String.split(arn, ":") do
      ["arn", "aws", "bedrock", region | _] when region != "" -> region
      _ -> nil
    end
  end

  defp random_id do
    :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
  end
end
