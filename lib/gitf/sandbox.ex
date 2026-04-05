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
      configured -> configured
      GiTF.Sandbox.Bubblewrap.available?() -> GiTF.Sandbox.Bubblewrap
      GiTF.Sandbox.SandboxExec.available?() -> GiTF.Sandbox.SandboxExec
      GiTF.Sandbox.Docker.available?() -> GiTF.Sandbox.Docker
      true -> GiTF.Sandbox.Local
    end
  end
end
