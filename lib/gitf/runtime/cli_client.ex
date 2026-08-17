defmodule GiTF.Runtime.CLIClient do
  @moduledoc """
  Subscription-billed `GiTF.Runtime.LLMClient` backend that drives the
  claude CLI.

  In `:cli` execution mode this is the ONLY in-process LLM backend: the
  operator picked a provider, and NOTHING may silently route to a metered
  API. Before this existed, in-process consumers (goal-fulfillment review,
  scoring, skills) went through ProviderCircuit → keyless Bedrock and
  quietly accrued real AWS spend (+$5.31 in the hours after the Max-plan
  flip) while ghost work billed the subscription.

  No token streaming: `stream_text/3` completes the generation and returns
  it whole — acceptable for the in-process consumers, which want final
  text, not typewriter output.
  """

  @behaviour GiTF.Runtime.LLMClient

  require Logger

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  @generation_timeout_ms 300_000

  @impl true
  def generate_text(model, messages, opts) do
    {system_prompt, prompt} = flatten_messages(messages)

    cli_model =
      model
      |> to_string()
      |> GiTF.Runtime.ModelResolver.resolve()
      |> GiTF.Runtime.Claude.cli_model_name()

    spawn_opts =
      [model: cli_model] ++
        if system_prompt != "", do: [system_prompt: system_prompt], else: []

    cwd = Keyword.get(opts, :cwd, System.tmp_dir!())

    with {:ok, port} <- GiTF.Runtime.Claude.spawn_headless(cwd, prompt, spawn_opts),
         {:ok, raw} <- collect(port) do
      {:ok, build_response(model, raw)}
    end
  end

  @impl true
  def stream_text(model, messages, opts) do
    generate_text(model, messages, opts)
  end

  # -- Internals ---------------------------------------------------------------

  defp collect(port), do: collect(port, [])

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} ->
        collect(port, [acc, data])

      {^port, {:exit_status, 0}} ->
        {:ok, IO.iodata_to_binary(acc)}

      {^port, {:exit_status, code}} ->
        out = IO.iodata_to_binary(acc)
        {:error, {:cli_exit, code, String.slice(out, -500, 500) || out}}
    after
      @generation_timeout_ms ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  @doc false
  # Public for tests: raw stream-json transcript → ReqLLM.Response with the
  # final text and real usage, so cost bookkeeping keeps working.
  def build_response(model, raw) do
    events = GiTF.Runtime.StreamParser.parse_chunk(raw)
    text = GiTF.Major.PhaseCollector.extract_assistant_text(events, raw)

    # extract_costs returns one entry per result event; the terminal one
    # carries the run's cumulative usage.
    costs =
      case GiTF.Runtime.StreamParser.extract_costs(events) do
        list when is_list(list) -> List.last(list) || %{}
        %{} = map -> map
        _ -> %{}
      end

    %ReqLLM.Response{
      id: nil,
      context: nil,
      model: Map.get(costs, :model) || to_string(model),
      message: %Message{
        role: :assistant,
        content: [ContentPart.text(text)]
      },
      usage: %{
        input_tokens: Map.get(costs, :input_tokens, 0),
        output_tokens: Map.get(costs, :output_tokens, 0),
        cache_read_tokens: Map.get(costs, :cache_read_tokens, 0),
        cache_write_tokens: Map.get(costs, :cache_write_tokens, 0),
        total_tokens: Map.get(costs, :input_tokens, 0) + Map.get(costs, :output_tokens, 0),
        cost_usd: Map.get(costs, :cost_usd)
      }
    }
  end

  @doc false
  # Public for tests: LLMClient accepts a bare string, a ReqLLM.Context, or
  # a list of role/content maps. Returns {system_prompt, user_prompt}.
  def flatten_messages(messages) when is_binary(messages), do: {"", messages}

  def flatten_messages(%{messages: msgs}) when is_list(msgs), do: flatten_list(msgs)
  def flatten_messages(messages) when is_list(messages), do: flatten_list(messages)
  def flatten_messages(other), do: {"", inspect(other)}

  defp flatten_list(msgs) do
    {systems, rest} =
      Enum.split_with(msgs, fn m -> role_of(m) in [:system, "system"] end)

    system_prompt = Enum.map_join(systems, "\n\n", &content_of/1)

    prompt =
      Enum.map_join(rest, "\n\n", fn m ->
        case role_of(m) do
          r when r in [:assistant, "assistant"] -> "Assistant: " <> content_of(m)
          _ -> content_of(m)
        end
      end)

    {system_prompt, prompt}
  end

  defp role_of(%{role: r}), do: r
  defp role_of(%{"role" => r}), do: r
  defp role_of(_), do: :user

  defp content_of(%{content: c}), do: content_text(c)
  defp content_of(%{"content" => c}), do: content_text(c)
  defp content_of(other), do: to_string_safe(other)

  defp content_text(c) when is_binary(c), do: c

  defp content_text(parts) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %{text: t} when is_binary(t) -> t
      %{"text" => t} when is_binary(t) -> t
      t when is_binary(t) -> t
      _ -> ""
    end)
  end

  defp content_text(other), do: to_string_safe(other)

  defp to_string_safe(v) when is_binary(v), do: v
  defp to_string_safe(v), do: inspect(v)
end
