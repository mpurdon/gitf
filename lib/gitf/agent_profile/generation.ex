defmodule GiTF.AgentProfile.Generation do
  @moduledoc """
  Shared generation helpers for model-based content generation.

  Used by `GiTF.AgentProfile` (sector-level technology agents) to spawn
  headless model sessions and collect their output.
  """

  @doc """
  Spawns a headless model session and collects its text output.

  Uses the active model provider via `GiTF.Runtime.Models.spawn_headless/3`.
  Returns `{:ok, text}` or `{:error, reason}`.
  """
  @spec generate_via_model(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def generate_via_model(prompt, cwd, opts \\ []) do
    if GiTF.Runtime.ModelResolver.api_mode?() do
      # API mode: use generate_text directly (no tools needed)
      GiTF.Runtime.Models.generate_text(prompt, opts)
    else
      case GiTF.Runtime.Models.find_executable(opts) do
        {:ok, _} ->
          case GiTF.Runtime.Models.spawn_headless(
                 prompt,
                 cwd,
                 Keyword.merge(opts, output_format: :text)
               ) do
            {:ok, port} ->
              collect_port_output(port)

            {:error, reason} ->
              {:error, reason}
          end

        {:error, :not_found} ->
          {:error, :model_not_found}
      end
    end
  end

  @doc """
  Collects all output from a port until it exits.

  Returns `{:ok, text}` on exit code 0, `{:error, reason}` otherwise.
  """
  @spec collect_port_output(port()) :: {:ok, String.t()} | {:error, term()}
  def collect_port_output(port) do
    collect_port_output(port, [])
  end

  defp collect_port_output(port, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, [acc, data])

      {^port, {:exit_status, 0}} ->
        output = IO.iodata_to_binary(acc)
        {:ok, extract_text_content(output)}

      {^port, {:exit_status, code}} ->
        {:error, {:exit_code, code}}
    after
      120_000 ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  @doc """
  Extracts text content from model output.

  Handles both stream-JSON format (Claude) and raw text output.
  """
  @spec extract_text_content(String.t()) :: String.t()
  def extract_text_content(output) do
    lines = String.split(output, "\n", trim: true)

    text_parts =
      Enum.flat_map(lines, fn line ->
        case Jason.decode(line) do
          {:ok, %{"type" => "assistant", "message" => %{"content" => content}}} ->
            content
            |> Enum.filter(fn block -> Map.get(block, "type") == "text" end)
            |> Enum.map(fn block -> Map.get(block, "text", "") end)

          {:ok, %{"type" => "result", "result" => result}} when is_binary(result) ->
            [result]

          _ ->
            []
        end
      end)

    case text_parts do
      [] -> output
      parts -> Enum.join(parts, "")
    end
  end
end
