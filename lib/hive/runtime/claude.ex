defmodule Hive.Runtime.Claude do
  @moduledoc """
  Manages the Claude Code CLI process lifecycle.

  This module wraps Erlang ports to launch `claude` as a subprocess. It
  provides two modes of operation:

  - **Interactive** (`spawn_interactive/2`): for the Queen, which runs
    Claude in an interactive terminal session.
  - **Headless** (`spawn_headless/3`): for Bees, which pipe a prompt to
    Claude and collect the output when it finishes.

  No GenServer here -- this is a utility module that creates and manages
  OS-level ports. The caller owns the port and receives its messages.
  """

  @common_locations [
    "/usr/local/bin/claude",
    "/usr/bin/claude",
    "/opt/homebrew/bin/claude"
  ]

  # -- Public API ------------------------------------------------------------

  @doc """
  Locates the `claude` executable on the system.

  Checks the PATH first via `System.find_executable/1`, then falls back to
  a list of common installation locations.

  Returns `{:ok, path}` or `{:error, :not_found}`.
  """
  @spec find_executable() :: {:ok, String.t()} | {:error, :not_found}
  def find_executable do
    case System.find_executable("claude") do
      nil -> check_common_locations()
      path -> {:ok, path}
    end
  end

  @doc """
  Spawns Claude in interactive mode for the Queen.

  Opens a port with a pseudo-terminal allocation, suitable for an
  interactive session. The calling process receives port messages.

  Returns `{:ok, port}` or `{:error, reason}`.
  """
  @spec spawn_interactive(String.t(), keyword()) :: {:ok, port()} | {:error, term()}
  def spawn_interactive(working_dir, opts \\ []) do
    with {:ok, claude_path} <- find_executable(),
         :ok <- validate_directory(working_dir) do
      args = build_interactive_args(opts)

      Hive.Runtime.Terminal.prepare_handoff()

      # Use :nouse_stdio so Claude inherits the real terminal directly.
      # This gives Claude full control of the TTY (raw mode, escape sequences,
      # TUI rendering) without needing a PTY wrapper or stdin/stdout relay.
      # The port communicates on fd 3/4 (unused), we only need :exit_status.
      port =
        Port.open({:spawn_executable, claude_path}, [
          :nouse_stdio,
          :exit_status,
          args: args,
          cd: working_dir,
          env: build_env(opts)
        ])

      {:ok, port}
    end
  end

  @doc """
  Spawns Claude in headless mode for a Bee.

  Sends a prompt via `--print` flag (or stdin) and collects output.
  Claude runs to completion and the port closes when done.

  Returns `{:ok, port}` or `{:error, reason}`.
  """
  @spec spawn_headless(String.t(), String.t(), keyword()) :: {:ok, port()} | {:error, term()}
  def spawn_headless(working_dir, prompt, opts \\ []) do
    with {:ok, claude_path} <- find_executable(),
         :ok <- validate_directory(working_dir) do
      args = build_headless_args(prompt, opts)

      # Always clear CLAUDECODE to prevent "nested session" errors when
      # bees are spawned from within a Claude Code session (e.g. the TUI).
      env = [{~c"CLAUDECODE", false} | build_env(opts)]

      port =
        Port.open({:spawn_executable, claude_path}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: args,
          cd: working_dir,
          env: env
        ])

      {:ok, port}
    end
  end

  @doc """
  Stops a Claude port process gracefully.

  Sends EOF to the port, then closes it. If the process does not exit
  within a reasonable time, the port will be force-closed by the BEAM.
  """
  @spec stop(port()) :: :ok
  def stop(port) when is_port(port) do
    if Port.info(port) != nil do
      Port.close(port)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Checks whether a Claude port is still running.

  Returns `true` if the port is open and the OS process has not exited.
  """
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
    base = []
    base = base ++ system_prompt_args(opts) ++ model_args(opts)
    base ++ prompt_args(opts)
  end

  defp build_headless_args(prompt, opts) do
    base = ["--print", "--dangerously-skip-permissions", "--output-format", "stream-json"]
    base = base ++ system_prompt_args(opts)
    base = base ++ resume_args(opts)
    base ++ [prompt] ++ model_args(opts)
  end

  defp system_prompt_args(opts) do
    case Keyword.get(opts, :system_prompt) do
      nil -> []
      prompt -> ["--system-prompt", prompt]
    end
  end

  defp prompt_args(opts) do
    case Keyword.get(opts, :prompt) do
      nil -> []
      prompt -> [prompt]
    end
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
    |> Enum.map(fn
      {k, false} -> {to_charlist(k), false}
      {k, v} -> {to_charlist(k), to_charlist(v)}
    end)
  end
end
