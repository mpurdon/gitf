defmodule GiTF.Test.ScriptedLLMClient do
  @moduledoc """
  A scripted implementation of `GiTF.Runtime.LLMClient` for pipeline
  simulations.

  Each scenario registers an ordered list of rules. When the agent loop
  calls `generate_text/3`, the client extracts the prompt text, walks the
  rule list, and returns the first rule whose `match` is present in the
  prompt. The rule supplies either a success response struct or an error
  to inject — the latter lets us simulate real failure modes (empty text,
  provider errors, etc.) without talking to a live LLM.

  Rules are consumed sequentially (each rule serves one call), so the
  same phase can be scripted to behave differently on first vs retry.

  Enable via `config :gitf, :llm_client, GiTF.Test.ScriptedLLMClient` in
  the simulator's test setup.
  """
  @behaviour GiTF.Runtime.LLMClient

  use Agent

  alias ReqLLM.{Message, Response}
  alias ReqLLM.Message.ContentPart

  @typedoc """
  A scripted rule:

    * `:match` — regex or substring tested against the concatenated prompt text.
    * `:response` — either `{:ok, %ReqLLM.Response{}}` or `{:error, reason}`.
    * `:consume` — whether this rule is removed after matching (default `true`).
  """
  @type rule :: %{
          required(:match) => Regex.t() | String.t(),
          required(:response) => {:ok, struct()} | {:error, term()},
          optional(:consume) => boolean()
        }

  # -- Agent state management --------------------------------------------------

  @doc """
  Starts the scripted client's state Agent. Call once per scenario;
  subsequent calls replace the rules.
  """
  def start_scenario(rules) when is_list(rules) do
    case Process.whereis(__MODULE__) do
      nil ->
        Agent.start_link(fn -> initial_state(rules) end, name: __MODULE__)

      pid ->
        Agent.update(__MODULE__, fn _ -> initial_state(rules) end)
        {:ok, pid}
    end
  end

  @doc "Returns the call log: each LLM call with its matched rule (or :unmatched)."
  def calls, do: Agent.get(__MODULE__, & &1.calls)

  @doc "Returns the number of unmatched calls (useful as an assertion signal)."
  def unmatched_count, do: Agent.get(__MODULE__, & &1.unmatched)

  @doc "Shuts the Agent down so the next scenario starts fresh."
  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> Agent.stop(pid)
    end
  end

  defp initial_state(rules) do
    %{
      rules: rules,
      calls: [],
      unmatched: 0
    }
  end

  # -- LLMClient behaviour -----------------------------------------------------

  @impl true
  def generate_text(model, messages, _opts) do
    prompt = extract_text(messages)

    {result, side_effect} =
      Agent.get_and_update(__MODULE__, fn state ->
        case pop_matching_rule(state.rules, prompt) do
          {:match, rule, rest} ->
            call_record = %{
              model: to_string(model),
              prompt_head: String.slice(prompt, 0, 120),
              rule: inspect(rule.match)
            }

            new_state = %{state | rules: rest, calls: [call_record | state.calls]}
            {{rule.response, Map.get(rule, :side_effect)}, new_state}

          :no_match ->
            call_record = %{
              model: to_string(model),
              prompt_head: String.slice(prompt, 0, 120),
              rule: :unmatched
            }

            response = {:error, {:simulator_no_matching_rule, String.slice(prompt, 0, 200)}}
            new_state = %{state | calls: [call_record | state.calls], unmatched: state.unmatched + 1}
            {{response, nil}, new_state}
        end
      end)

    # Run the side effect AFTER Agent state update so the hook can see
    # the finalized rule/call log and mutate external state (commit files
    # to a shell worktree, flip a feature flag, etc.).
    if is_function(side_effect, 0) do
      try do
        side_effect.()
      rescue
        e ->
          require Logger
          Logger.warning("ScriptedLLMClient side_effect raised: #{Exception.message(e)}")
      end
    end

    result
  end

  @impl true
  def stream_text(_model, _messages, _opts) do
    {:error, :streaming_not_supported_in_simulator}
  end

  # -- Rule matching -----------------------------------------------------------

  defp pop_matching_rule(rules, prompt) do
    Enum.reduce_while(rules, {[], rules}, fn rule, {_seen, remaining} ->
      if match_rule?(rule.match, prompt) do
        consume? = Map.get(rule, :consume, true)

        rest =
          if consume?,
            do: List.delete(remaining, rule),
            else: remaining

        {:halt, {:match, rule, rest}}
      else
        {:cont, {[rule], remaining}}
      end
    end)
    |> case do
      {:match, _rule, _rest} = result -> result
      _ -> :no_match
    end
  end

  defp match_rule?(%Regex{} = re, prompt), do: Regex.match?(re, prompt)
  defp match_rule?(s, prompt) when is_binary(s), do: String.contains?(prompt, s)
  defp match_rule?(_, _), do: false

  # -- Prompt extraction -------------------------------------------------------

  # Concatenates text parts from a ReqLLM.Context or a plain string/list.
  # Tool-result parts are included so rules can match on mid-loop state too.
  defp extract_text(text) when is_binary(text), do: text

  defp extract_text(%{messages: messages}) when is_list(messages) do
    Enum.map_join(messages, "\n", &message_text/1)
  end

  defp extract_text(messages) when is_list(messages) do
    Enum.map_join(messages, "\n", &message_text/1)
  end

  defp extract_text(_), do: ""

  defp message_text(%Message{content: content}) when is_list(content) do
    content
    |> Enum.map(&content_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp message_text(%{content: content}) when is_binary(content), do: content

  defp message_text(%{content: content}) when is_list(content) do
    Enum.map_join(content, "\n", &content_text/1)
  end

  defp message_text(_), do: ""

  defp content_text(%ContentPart{type: :text, text: t}) when is_binary(t), do: t
  defp content_text(%{type: :text, text: t}) when is_binary(t), do: t
  defp content_text(%{text: t}) when is_binary(t), do: t
  defp content_text(t) when is_binary(t), do: t
  defp content_text(_), do: ""

  # -- Convenience helpers for scenarios ---------------------------------------

  @doc """
  Builds a plain-text successful response. Use in scenario rules for
  phases that just need to emit a JSON artifact — the agent loop will
  parse whatever the ghost returns as the "final answer".
  """
  @spec ok_text(String.t(), keyword()) :: {:ok, Response.t()}
  def ok_text(text, opts \\ []) do
    model = Keyword.get(opts, :model, "sim:mock")
    input_tokens = Keyword.get(opts, :input_tokens, 100)
    output_tokens = Keyword.get(opts, :output_tokens, 50)

    response = %Response{
      id: "sim-#{:erlang.unique_integer([:positive])}",
      model: model,
      context: nil,
      message: %Message{
        role: :assistant,
        content: [%ContentPart{type: :text, text: text}]
      },
      object: nil,
      stream?: false,
      stream: nil,
      usage: %{
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        total_tokens: input_tokens + output_tokens
      },
      finish_reason: :stop,
      provider_meta: %{},
      error: nil
    }

    {:ok, response}
  end

  @doc """
  Builds an empty-text response with the given usage. Exercises the
  `:empty_response` detection path in `GiTF.Runtime.AgentLoop`.
  """
  @spec empty_response(keyword()) :: {:ok, Response.t()}
  def empty_response(opts \\ []) do
    {:ok, resp} = ok_text("", opts)
    {:ok, resp}
  end

  @doc """
  Wraps a phase JSON artifact in a ```json fence, matching what phase
  ghosts actually return. `GiTF.Major.PhaseCollector` extracts the fenced
  block and parses it.
  """
  @spec json_artifact(map()) :: String.t()
  def json_artifact(data) do
    "```json\n" <> Jason.encode!(data, pretty: true) <> "\n```"
  end
end
