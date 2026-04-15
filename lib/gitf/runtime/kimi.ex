defmodule GiTF.Runtime.Kimi do
  @moduledoc """
  Manages the Kimi CLI process lifecycle.

  Same structure as `GiTF.Runtime.Claude` but with Kimi-specific flags.
  Kimi CLI uses the same JSONL streaming format as Claude, so the output
  is parsed by `GiTF.Runtime.StreamParser`.

  - **Interactive** (`spawn_interactive/2`): launches Kimi's TUI
  - **Headless** (`spawn_headless/3`): runs a single prompt to completion
  """

  # Rely on PATH via System.find_executable/1. Hardcoded fallbacks
  # (e.g. /opt/homebrew/bin) are platform-specific and mask real problems.
  @common_locations []

  # -- Public API ------------------------------------------------------------

  @spec find_executable() :: {:ok, String.t()} | {:error, :not_found}
  def find_executable do
    case System.find_executable("kimi") do
      nil -> check_common_locations()
      path -> {:ok, path}
    end
  end

  @spec spawn_interactive(String.t(), keyword()) :: {:ok, port()} | {:error, term()}
  def spawn_interactive(working_dir, opts \\ []) do
    with {:ok, kimi_path} <- find_executable(),
         :ok <- validate_directory(working_dir) do
      args = build_interactive_args(opts)

      GiTF.Runtime.Terminal.prepare_handoff()

      port =
        Port.open({:spawn_executable, kimi_path}, [
          :nouse_stdio,
          :exit_status,
          args: args,
          cd: working_dir,
          env: build_env(opts)
        ])

      {:ok, port}
    end
  end

  @spec spawn_headless(String.t(), String.t(), keyword()) :: {:ok, port()} | {:error, term()}
  def spawn_headless(working_dir, prompt, opts \\ []) do
    with {:ok, kimi_path} <- find_executable(),
         :ok <- validate_directory(working_dir) do
      args = build_headless_args(prompt, opts)

      port =
        Port.open({:spawn_executable, kimi_path}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: args,
          cd: working_dir,
          env: build_env(opts)
        ])

      {:ok, port}
    end
  end

  @spec stop(port()) :: :ok
  def stop(port) when is_port(port) do
    if Port.info(port) != nil do
      Port.close(port)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec alive?(port()) :: boolean()
  def alive?(port) when is_port(port) do
    Port.info(port) != nil
  rescue
    ArgumentError -> false
  end

  # -- Private helpers -------------------------------------------------------

  defp check_common_locations do
    case Enum.find(@common_locations, &File.exists?/1) do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  defp validate_directory(path) do
    if File.dir?(path), do: :ok, else: {:error, :invalid_working_dir}
  end

  defp build_interactive_args(opts) do
    model_args(opts)
  end

  defp build_headless_args(prompt, opts) do
    base = ["--print", "--output-format", "stream-json"]
    base = base ++ resume_args(opts)
    base ++ ["-p", prompt] ++ model_args(opts)
  end

  defp resume_args(opts) do
    case Keyword.get(opts, :resume) do
      nil -> []
      session_id -> ["--resume", "--session-id", session_id]
    end
  end

  defp model_args(opts) do
    case Keyword.get(opts, :model) do
      nil -> []
      model -> ["--model", model]
    end
  end

  defp build_env(opts) do
    Keyword.get(opts, :env, [])
    |> Enum.map(fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
  end
end
