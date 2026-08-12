defmodule GiTF.Sandbox.PolicyError do
  @moduledoc "Raised when `sandbox_required` is set but no kernel sandbox is effective."
  defexception message: "sandbox required but unavailable"
end

defmodule GiTF.Sandbox do
  @moduledoc """
  Behaviour for command execution sandboxing.

  Allows wrapping command execution in isolated environments like Bubblewrap
  or Docker to prevent accidental damage to the host system.
  """

  @callback wrap_command(String.t(), [String.t()], keyword()) ::
              {String.t(), [String.t()], keyword()}
  @callback available?() :: boolean()
  @callback name() :: String.t()

  @doc """
  Wraps a command and its arguments in the configured sandbox.
  """
  def wrap_command(cmd, args, opts \\ []) do
    adapter().wrap_command(cmd, args, opts)
  end

  @doc """
  Returns true if the configured sandbox adapter is available on this system.
  """
  def available? do
    adapter().available?()
  end

  @doc """
  Whether sandboxing is enabled (config `[:gitf, :sandbox_enabled]`, default
  true). Lets an operator disable sandboxing globally if a profile proves too
  restrictive for their toolchain.
  """
  def enabled? do
    Application.get_env(:gitf, :sandbox_enabled, true) != false
  end

  @doc """
  Whether a working kernel sandbox is mandatory (config
  `[:gitf, :sandbox_required]` / env `GITF_SANDBOX_REQUIRED`, default false).

  When true, spawn sites refuse to run AI-authored commands unsandboxed
  instead of falling back with a warning. Set this on any server deployment:
  the fail-open default exists for interactive dev machines, where a missing
  `bwrap` should degrade rather than block, but on a daemon it turns a
  missing package into silent unconfined execution.
  """
  @spec required?() :: boolean()
  def required? do
    Application.get_env(:gitf, :sandbox_required, false) == true
  end

  @doc """
  True when commands will actually run inside a kernel sandbox: sandboxing is
  enabled, a non-local adapter selected itself, and its binary is on PATH.
  """
  @spec effective?() :: boolean()
  def effective? do
    enabled?() and available?() and name() != "local" and
      case wrap_command("true", [], []) do
        {sb_cmd, _args, _opts} -> System.find_executable(sb_cmd) != nil
      end
  rescue
    _ -> false
  end

  @doc """
  `:ok` when spawning is permitted under the current policy —
  either a sandbox is effective, or one isn't required.
  """
  @spec check_policy() :: :ok | {:error, :sandbox_required_but_unavailable}
  def check_policy do
    if required?() and not effective?() do
      {:error, :sandbox_required_but_unavailable}
    else
      :ok
    end
  end

  @doc """
  Returns `{cmd, args}` for running `sh -c command` through the configured
  kernel sandbox, or the unsandboxed `{"sh", ["-c", command]}` when no real
  sandbox is enabled/available. Intended for `System.cmd/3`.

  Use this for executing AI-authored test/validation commands so they cannot
  damage the host outside the worktree.
  """
  @spec wrap_shell(String.t(), keyword()) :: {String.t(), [String.t()]}
  def wrap_shell(command, opts \\ []) do
    cwd = Keyword.get(opts, :cd, File.cwd!())
    risk = Keyword.get(opts, :risk_level, :low)

    if enabled?() and available?() and name() != "local" do
      {sb_cmd, sb_args, _} = wrap_command("sh", ["-c", command], cd: cwd, risk_level: risk)

      case System.find_executable(sb_cmd) do
        nil -> unsandboxed_shell(command)
        _ -> {sb_cmd, sb_args}
      end
    else
      unsandboxed_shell(command)
    end
  end

  # Unsandboxed fallback is only permitted when policy allows it; under
  # `sandbox_required` this raises so the surrounding op fails loudly rather
  # than running AI-authored commands unconfined.
  defp unsandboxed_shell(command) do
    case check_policy() do
      :ok ->
        {"sh", ["-c", command]}

      {:error, :sandbox_required_but_unavailable} ->
        raise GiTF.Sandbox.PolicyError,
              "sandbox_required is set but no kernel sandbox is effective " <>
                "(adapter: #{name()}) — refusing to run shell command unsandboxed"
    end
  end

  @doc """
  Returns the name of the active sandbox adapter.
  """
  def name do
    adapter().name()
  end

  @doc """
  Converts a command and arguments tuple into a shell-safe string.
  """
  def to_shell_string(cmd, args) do
    ([cmd] ++ args)
    |> Enum.map(&escape_shell_arg/1)
    |> Enum.join(" ")
  end

  defp escape_shell_arg(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  defp adapter do
    configured = Application.get_env(:gitf, :sandbox_adapter)

    cond do
      configured ->
        configured

      true ->
        # Prefer the OS-native sandbox adapter first:
        # - macOS -> sandbox-exec
        # - Linux -> bubblewrap
        # Fall back to Docker, then Local.
        case :os.type() do
          {:unix, :darwin} ->
            cond do
              GiTF.Sandbox.SandboxExec.available?() -> GiTF.Sandbox.SandboxExec
              GiTF.Sandbox.Docker.available?() -> GiTF.Sandbox.Docker
              true -> GiTF.Sandbox.Local
            end

          {:unix, :linux} ->
            cond do
              GiTF.Sandbox.Bubblewrap.available?() -> GiTF.Sandbox.Bubblewrap
              GiTF.Sandbox.Docker.available?() -> GiTF.Sandbox.Docker
              true -> GiTF.Sandbox.Local
            end

          _ ->
            if GiTF.Sandbox.Docker.available?(),
              do: GiTF.Sandbox.Docker,
              else: GiTF.Sandbox.Local
        end
    end
  end
end
