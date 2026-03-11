defmodule GiTF.Plugin.Builtin.Models.Claude do
  @moduledoc """
  Built-in Claude model plugin. Wraps existing `GiTF.Runtime.Claude`
  functions behind the `GiTF.Plugin.Model` behaviour.
  """

  use GiTF.Plugin, type: :model

  @impl true
  def name, do: "claude"

  @impl true
  def description, do: "Anthropic Claude via Claude Code CLI"

  @impl true
  def spawn_interactive(cwd, opts \\ []) do
    GiTF.Runtime.Claude.spawn_interactive(cwd, opts)
  end

  @impl true
  def spawn_headless(prompt, cwd, opts \\ []) do
    GiTF.Runtime.Claude.spawn_headless(cwd, prompt, opts)
  end

  @impl true
  def parse_output(data) do
    GiTF.Runtime.StreamParser.parse_chunk(data)
  end

  @impl true
  def find_executable do
    GiTF.Runtime.Claude.find_executable()
  end

  @impl true
  def workspace_setup(bee_or_major, gitf_root) do
    case bee_or_major do
      "major" -> GiTF.Runtime.Settings.build_major_settings(gitf_root)
      ghost_id -> GiTF.Runtime.Settings.build_settings(ghost_id, gitf_root)
    end
  end

  @impl true
  def pricing do
    %{
      "claude-opus" => %{
        input: 15.0,
        output: 75.0,
        cache_read: 1.50,
        cache_write: 18.75
      },
      "claude-sonnet" => %{
        input: 3.0,
        output: 15.0,
        cache_read: 0.30,
        cache_write: 3.75
      },
      "claude-haiku" => %{
        input: 0.80,
        output: 4.0,
        cache_read: 0.08,
        cache_write: 1.0
      },
      # Legacy full model names
      "claude-sonnet-4-20250514" => %{
        input: 3.0,
        output: 15.0,
        cache_read: 0.30,
        cache_write: 3.75
      },
      "claude-opus-4-20250514" => %{
        input: 15.0,
        output: 75.0,
        cache_read: 1.50,
        cache_write: 18.75
      }
    }
  end

  @impl true
  def list_available_models do
    ["claude-opus", "claude-sonnet", "claude-haiku"]
  end

  @impl true
  def get_model_info(model) do
    case model do
      "claude-opus" ->
        {:ok,
         %{
           name: "claude-opus",
           full_name: "claude-opus-4-20250514",
           context_limit: 200_000,
           capabilities: [:planning, :complex_implementation, :architecture],
           cost_tier: :high
         }}

      "claude-sonnet" ->
        {:ok,
         %{
           name: "claude-sonnet",
           full_name: "claude-sonnet-4-20250514",
           context_limit: 200_000,
           capabilities: [:implementation, :refactoring, :debugging],
           cost_tier: :medium
         }}

      "claude-haiku" ->
        {:ok,
         %{
           name: "claude-haiku",
           full_name: "claude-haiku-3-20250219",
           context_limit: 200_000,
           capabilities: [:research, :summarization, :audit],
           cost_tier: :low
         }}

      _ ->
        {:error, :unknown_model}
    end
  end

  @impl true
  def get_context_limit(model) do
    case get_model_info(model) do
      {:ok, info} -> {:ok, info.context_limit}
      error -> error
    end
  end

  @impl true
  def capabilities, do: [:tool_calling, :streaming, :interactive, :headless]

  @impl true
  def extract_costs(events) do
    GiTF.Runtime.StreamParser.extract_costs(events)
  end

  @impl true
  def extract_session_id(events) do
    GiTF.Runtime.StreamParser.extract_session_id(events)
  end

  @impl true
  def progress_from_events(events) do
    Enum.reduce(events, [], fn event, acc ->
      case event do
        %{"type" => "tool_use", "name" => tool} ->
          file = get_in(event, ["input", "file_path"]) || ""
          [%{tool: tool, file: file, message: "Using #{tool}"} | acc]

        %{"type" => "assistant", "content" => content} when is_binary(content) ->
          [%{tool: nil, file: nil, message: String.slice(content, 0, 120)} | acc]

        _ ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  @impl true
  def detached_command(prompt, _opts) do
    case GiTF.Runtime.Claude.find_executable() do
      {:ok, claude_path} ->
        escaped = "'" <> String.replace(prompt, "'", "'\\''") <> "'"

        ~s("#{claude_path}" --print --dangerously-skip-permissions --verbose --output-format stream-json #{escaped})

      {:error, :not_found} ->
        raise "Claude executable not found"
    end
  end
end
