defmodule GiTF.Runtime.Terminal do
  @moduledoc """
  Shared terminal utilities for interactive CLI providers.

  Before handing the TTY to an interactive child process (Claude, Copilot,
  Kimi, etc.), the BEAM's terminal state needs to be cleaned up:

  1. Flush pending IO so it doesn't interleave with the child's TUI
  2. Reset terminal to sane defaults (the BEAM may have altered settings)
  3. Restore default OS signal handling so the child gets SIGINT/SIGWINCH
  """

  @doc """
  Prepares the terminal for transfer to an interactive child process.

  Call this before spawning any TUI-based CLI with `:nouse_stdio`.
  """
  @spec prepare_handoff() :: :ok
  def prepare_handoff do
    :io.put_chars(:standard_io, "")
    reset_terminal()
    restore_default_signals()
  end

  @doc """
  Resets the terminal to sane defaults.

  The BEAM may have altered terminal settings (echo, buffering, etc.)
  during startup that would interfere with a child's raw-mode TUI.
  """
  @spec reset_terminal() :: :ok
  def reset_terminal do
    System.cmd("stty", ["sane"], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Restores default OS signal handling.

  Ensures the interactive child process receives SIGINT (Ctrl+C),
  SIGWINCH (resize), and SIGTSTP (Ctrl+Z) directly, instead of
  the BEAM intercepting them.
  """
  @spec restore_default_signals() :: :ok
  def restore_default_signals do
    for sig <- [:sigint, :sigwinch, :sigtstp] do
      try do
        :os.set_signal(sig, :default)
      rescue
        _ -> :ok
      end
    end

    :ok
  end
end
