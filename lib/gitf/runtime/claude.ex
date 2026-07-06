defmodule GiTF.Runtime.Claude do
  @moduledoc """
  Manages the Claude Code CLI process lifecycle.

  This module wraps Erlang ports to launch `claude` as a subprocess. It
  provides two modes of operation:

  - **Interactive** (`spawn_interactive/2`): for the Major, which runs
    Claude in an interactive terminal session.
  - **Headless** (`spawn_headless/3`): for Ghosts, which pipe a prompt to
    Claude and collect the output when it finishes.

  No GenServer here -- this is a utility module that creates and manages
  OS-level ports. The caller owns the port and receives its messages.
  """

  require Logger

  # Rely on PATH via System.find_executable/1. Hardcoded fallbacks
  # (e.g. /opt/homebrew/bin) are platform-specific and mask real problems.
  @common_locations []

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
  Spawns Claude in interactive mode for the Major.

  Opens a port with a pseudo-terminal allocation, suitable for an
  interactive session. The calling process receives port messages.

  Returns `{:ok, port}` or `{:error, reason}`.
  """
  @spec spawn_interactive(String.t(), keyword()) :: {:ok, port()} | {:error, term()}
  def spawn_interactive(working_dir, opts \\ []) do
    with {:ok, claude_path} <- find_executable(),
         :ok <- validate_directory(working_dir) do
      args = build_interactive_args(opts)

      GiTF.Runtime.Terminal.prepare_handoff()

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
  Spawns Claude in headless mode for a Ghost.

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
      # ghosts are spawned from within a Claude Code session (e.g. the TUI).
      env = [{~c"CLAUDECODE", false} | build_env(opts)]

      # Ghost CLIs run AI-authored code with --dangerously-skip-permissions.
      # Sandbox the spawn (kernel-level: sandbox-exec on macOS, bubblewrap on
      # Linux) so that damage is confined to the worktree + tmp. Falls back to
      # a direct spawn with a loud warning if no real sandbox is available,
      # rather than silently failing to launch.
      {exe, exe_args} = sandbox_wrap(claude_path, args, working_dir, opts)

      port =
        Port.open({:spawn_executable, exe}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: exe_args,
          cd: working_dir,
          env: env
        ])

      {:ok, port}
    end
  end

  # Returns `{executable_path, args}` to spawn, wrapped in the configured
  # sandbox when one is available and enabled; otherwise the command unchanged.
  defp sandbox_wrap(cmd, args, working_dir, opts) do
    if sandbox_enabled?() and GiTF.Sandbox.available?() and GiTF.Sandbox.name() != "local" do
      risk = Keyword.get(opts, :risk_level, :low)
      {sb_cmd, sb_args, _opts} = GiTF.Sandbox.wrap_command(cmd, args, cd: working_dir, risk_level: risk)

      case System.find_executable(sb_cmd) do
        nil ->
          Logger.warning("Sandbox #{sb_cmd} not on PATH — spawning ghost UNSANDBOXED")
          {cmd, args}

        sb_path ->
          {sb_path, sb_args}
      end
    else
      unless sandbox_enabled?() do
        :ok
      else
        Logger.warning("No kernel sandbox available — spawning ghost UNSANDBOXED")
      end

      {cmd, args}
    end
  end

  defp sandbox_enabled?, do: GiTF.Sandbox.enabled?()

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

  # AWS credentials are loaded into the BEAM node env (via System.put_env) for
  # the in-process Bedrock provider. Erlang ports inherit the node env, so
  # those secrets would otherwise leak into every spawned CLI subprocess —
  # which runs AI-authored code and never needs AWS. Scrub them from the child
  # environment (`{var, false}` removes the var for that port).
  @scrubbed_env_vars ~w(
    AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    AWS_SECURITY_TOKEN AWS_BEARER_TOKEN_BEDROCK
  )

  defp build_env(opts) do
    passthrough =
      Keyword.get(opts, :env, [])
      |> Enum.map(fn
        {k, false} -> {to_charlist(k), false}
        {k, v} -> {to_charlist(k), to_charlist(v)}
      end)

    explicit_keys = MapSet.new(passthrough, fn {k, _} -> k end)

    scrub =
      for var <- @scrubbed_env_vars,
          key = to_charlist(var),
          not MapSet.member?(explicit_keys, key),
          do: {key, false}

    scrub ++ passthrough
  end
end
