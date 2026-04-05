defmodule GiTF.Plugin.Builtin.Models.ReqLLMProvider do
  @moduledoc """
  Generic multi-provider API plugin using ReqLLM.

  Implements the `GiTF.Plugin.Model` behaviour for API mode. Supports
  45+ LLM providers (Anthropic, Google, OpenAI, Groq, etc.) via ReqLLM's
  unified interface.

  In API mode, `run_agent/3` delegates to `AgentLoop.run/3` and
  `generate_text/2` delegates to `ReqLLM.generate_text/3`.

  The CLI-only callbacks (`spawn_interactive/2`, `spawn_headless/3`)
  return `{:error, :not_supported_in_api_mode}`.
  """

  use GiTF.Plugin, type: :model

  alias GiTF.Runtime.{AgentLoop, ModelResolver}

  @impl true
  def name, do: "reqllm"

  @impl true
  def description, do: "Multi-provider LLM API via ReqLLM"

  @impl true
  def execution_mode, do: :api

  # -- API-mode callbacks ------------------------------------------------------

  @impl true
  def run_agent(prompt, working_dir, opts \\ []) do
    AgentLoop.run(prompt, working_dir, opts)
  end

  @impl true
  def generate_text(prompt, opts \\ []) do
    model = Keyword.get(opts, :model) |> resolve_model_spec()
    system_prompt = Keyword.get(opts, :system_prompt)

    messages =
      if system_prompt do
        ReqLLM.Context.new([
          ReqLLM.Context.system(system_prompt),
          ReqLLM.Context.user(prompt)
        ])
      else
        prompt
      end

    generate_opts =
      opts
      |> Keyword.drop([:model, :system_prompt, :output_format])
      |> Keyword.take([:max_tokens, :temperature])

    case ReqLLM.generate_text(model, messages, generate_opts) do
      {:ok, response} ->
        {:ok, ReqLLM.Response.text(response) || ""}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- CLI-mode stubs (not supported) ------------------------------------------

  @impl true
  def spawn_interactive(_cwd, _opts \\ []) do
    {:error, :not_supported_in_api_mode}
  end

  @impl true
  def spawn_headless(_prompt, _cwd, _opts \\ []) do
    {:error, :not_supported_in_api_mode}
  end

  @impl true
  def parse_output(_data), do: []

  # -- Optional callbacks ------------------------------------------------------

  @impl true
  def capabilities, do: [:tool_calling, :streaming, :api_mode, :multi_provider]

  @impl true
  def pricing do
    %{
      # Google models (defaults)
      "google:gemini-2.5-pro" => %{
        input: 1.25,
        output: 10.0,
        cache_read: 0.315,
        cache_write: 0.0
      },
      "google:gemini-2.5-flash" => %{
        input: 0.15,
        output: 0.60,
        cache_read: 0.0375,
        cache_write: 0.0
      },
      "google:gemini-2.0-flash" => %{
        input: 0.10,
        output: 0.40,
        cache_read: 0.025,
        cache_write: 0.0
      },
      # Anthropic models (direct API)
      "anthropic:claude-opus-4-6" => %{
        input: 15.0,
        output: 75.0,
        cache_read: 1.50,
        cache_write: 18.75
      },
      "anthropic:claude-sonnet-4-6" => %{
        input: 3.0,
        output: 15.0,
        cache_read: 0.30,
        cache_write: 3.75
      },
      "anthropic:claude-haiku-4-5" => %{
        input: 0.80,
        output: 4.0,
        cache_read: 0.08,
        cache_write: 1.0
      },
      # Bedrock models (AWS)
      "bedrock:anthropic.claude-sonnet-4-6" => %{
        input: 3.0,
        output: 15.0,
        cache_read: 0.30,
        cache_write: 3.75
      },
      "bedrock:anthropic.claude-haiku-4-5" => %{
        input: 0.80,
        output: 4.0,
        cache_read: 0.08,
        cache_write: 1.0
      },
      "bedrock:amazon.nova-pro" => %{
        input: 0.80,
        output: 3.20,
        cache_read: 0.0,
        cache_write: 0.0
      },
      "bedrock:amazon.nova-lite" => %{
        input: 0.06,
        output: 0.24,
        cache_read: 0.0,
        cache_write: 0.0
      },
      # OpenAI models
      "openai:gpt-4o" => %{
        input: 2.50,
        output: 10.0,
        cache_read: 1.25,
        cache_write: 0.0
      },
      "openai:gpt-4o-mini" => %{
        input: 0.15,
        output: 0.60,
        cache_read: 0.075,
        cache_write: 0.0
      }
      # Ollama models
      # Use "ollama:llama3.3", "ollama:qwen2.5-coder", etc.
    }
  end

  @impl true
  def list_available_models do
    [
      # Google (defaults)
      "google:gemini-2.5-pro",
      "google:gemini-2.5-flash",
      "google:gemini-2.0-flash",
      # Anthropic (direct API)
      "anthropic:claude-opus-4-6",
      "anthropic:claude-sonnet-4-6",
      "anthropic:claude-haiku-4-5",
      # Bedrock (AWS)
      "bedrock:anthropic.claude-sonnet-4-6",
      "bedrock:anthropic.claude-haiku-4-5",
      "bedrock:amazon.nova-pro",
      "bedrock:amazon.nova-lite",
      # OpenAI
      "openai:gpt-4o",
      "openai:gpt-4o-mini"
      # Ollama: use "ollama:<model>"
    ]
  end

  @impl true
  def get_model_info(model) do
    resolved = ModelResolver.resolve(model)
    {:ok, ctx_limit} = get_context_limit(resolved)

    info = %{
      name: resolved,
      provider: ModelResolver.provider(resolved),
      context_limit: ctx_limit,
      capabilities: [:tool_calling, :streaming],
      cost_tier: infer_cost_tier(resolved)
    }

    {:ok, info}
  end

  @impl true
  def get_context_limit(model) do
    limit =
      cond do
        String.contains?(model, "gemini-2.5") -> 1_048_576
        String.contains?(model, "gemini-2.0") -> 1_048_576
        String.contains?(model, "claude-opus") -> 200_000
        String.contains?(model, "claude-sonnet") -> 200_000
        String.contains?(model, "claude-haiku") -> 200_000
        String.contains?(model, "gpt-4o") -> 128_000
        String.contains?(model, "nova-pro") -> 300_000
        String.contains?(model, "nova-lite") -> 300_000
        true -> 200_000
      end

    {:ok, limit}
  end

  @impl true
  def extract_costs(events) do
    events
    |> Enum.filter(fn e -> Map.get(e, "type") == "result" end)
    |> Enum.map(fn e ->
      usage = Map.get(e, "usage", %{})

      %{
        input_tokens: Map.get(usage, :input_tokens, 0),
        output_tokens: Map.get(usage, :output_tokens, 0),
        cache_read_tokens: 0,
        cache_write_tokens: 0,
        model: Map.get(e, "model"),
        cost_usd: Map.get(e, "cost_usd", 0)
      }
    end)
  end

  @impl true
  def extract_session_id(events) do
    Enum.find_value(events, fn
      %{"type" => "system", "session_id" => sid} -> sid
      %{"type" => "result", "session_id" => sid} -> sid
      _ -> nil
    end)
  end

  @impl true
  def progress_from_events(events) do
    Enum.reduce(events, [], fn event, acc ->
      case event do
        %{"type" => "tool_use", "name" => tool} ->
          input = Map.get(event, "input", %{})
          file = Map.get(input, "path", "")
          [%{tool: tool, file: file, message: "Using #{tool}"} | acc]

        _ ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  # -- Private -----------------------------------------------------------------

  defp resolve_model_spec(nil), do: ModelResolver.resolve("sonnet")
  defp resolve_model_spec(model), do: ModelResolver.resolve(model)

  defp infer_cost_tier(model) do
    cond do
      String.contains?(model, "opus") or String.contains?(model, "gemini-2.5-pro") ->
        :high

      String.contains?(model, "haiku") or String.contains?(model, "flash") or
        String.contains?(model, "mini") or String.contains?(model, "nova-lite") or
        String.contains?(model, "llama") or String.contains?(model, "qwen") ->
        :low

      true ->
        :medium
    end
  end
end
