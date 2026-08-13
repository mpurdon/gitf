defmodule GiTF.Runtime.OsProc do
  @moduledoc """
  Best-effort termination of OS subprocesses spawned via Erlang ports.

  Closing an Erlang port does **not** reliably kill the underlying OS
  process. A program that is not reading stdin never receives SIGPIPE and
  keeps running after `Port.close/1` — holding its git worktree and, for an
  AI CLI, continuing to burn API spend indefinitely. This module sends a
  real signal to the OS pid: SIGTERM first (graceful), then SIGKILL after a
  grace period, and reaps direct children so node/subagent processes don't
  orphan.

  All operations are best-effort and never raise: a missing `kill`/`pkill`
  or an already-dead pid resolves to `:ok`.
  """

  require Logger

  @default_grace_ms 2_000

  @doc """
  Fetch the OS pid backing a port, or `nil` if unavailable.
  """
  @spec port_pid(port()) :: pos_integer() | nil
  def port_pid(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) -> pid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def port_pid(_), do: nil

  @doc """
  Terminate an OS process: SIGTERM, wait `:grace_ms`, then SIGKILL if it is
  still alive. Reaps direct children with the same signal. Accepts an
  integer pid, a numeric string, or `nil` (no-op). Blocks up to `:grace_ms`.
  """
  @spec terminate(pos_integer() | String.t() | nil, keyword()) :: :ok
  def terminate(nil, _opts), do: :ok

  def terminate(os_pid, opts) when is_binary(os_pid) do
    case Integer.parse(os_pid) do
      {pid, _} -> terminate(pid, opts)
      :error -> :ok
    end
  end

  def terminate(os_pid, opts) when is_integer(os_pid) and os_pid > 0 do
    grace = Keyword.get(opts, :grace_ms, @default_grace_ms)

    if alive?(os_pid) do
      signal(os_pid, "TERM")
      reap_children(os_pid, "TERM")

      unless wait_for_exit(os_pid, grace) do
        Logger.warning("OS process #{os_pid} survived SIGTERM after #{grace}ms; sending SIGKILL")
        signal(os_pid, "KILL")
        reap_children(os_pid, "KILL")
      end
    end

    :ok
  end

  def terminate(_, _), do: :ok

  @doc """
  Terminate an OS process without blocking the caller by running
  `terminate/2` in an unlinked, unsupervised process. Use from a GenServer
  that must not stall on the grace period.
  """
  @spec terminate_async(pos_integer() | String.t() | nil, keyword()) :: :ok
  def terminate_async(nil, _opts), do: :ok

  def terminate_async(os_pid, opts) do
    spawn(fn -> terminate(os_pid, opts) end)
    :ok
  end

  @doc "Whether an OS pid is currently alive (via `kill -0`)."
  @spec alive?(pos_integer() | String.t() | nil) :: boolean()
  def alive?(nil), do: false

  def alive?(os_pid) when is_binary(os_pid) do
    case Integer.parse(os_pid) do
      {pid, _} -> alive?(pid)
      :error -> false
    end
  end

  def alive?(os_pid) when is_integer(os_pid) and os_pid > 0 do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} -> not zombie?(os_pid)
      _ -> false
    end
  rescue
    _ -> false
  end

  def alive?(_), do: false

  # -- Private ---------------------------------------------------------------

  # `kill -0` succeeds for zombies, but a zombie is only an unreaped exit
  # record: it can't run, produce output, or be killed harder. Every caller
  # (stall recovery, the reaper, tests) should treat it as dead — counting
  # zombies as alive makes recovery loop forever on unkillable ghosts, e.g.
  # in containers where no init reaps orphans.
  defp zombie?(os_pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(os_pid)],
           stderr_to_stdout: true
         ) do
      {out, 0} -> out |> String.trim() |> String.starts_with?("Z")
      _ -> false
    end
  rescue
    _ -> false
  end

  defp signal(os_pid, sig) do
    System.cmd("kill", ["-#{sig}", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp reap_children(os_pid, sig) do
    case System.find_executable("pkill") do
      nil ->
        :ok

      pkill ->
        System.cmd(pkill, ["-#{sig}", "-P", Integer.to_string(os_pid)], stderr_to_stdout: true)
        :ok
    end
  rescue
    _ -> :ok
  end

  defp wait_for_exit(os_pid, grace_ms) do
    deadline = System.monotonic_time(:millisecond) + grace_ms
    do_wait(os_pid, deadline)
  end

  defp do_wait(os_pid, deadline) do
    cond do
      not alive?(os_pid) -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true ->
        Process.sleep(100)
        do_wait(os_pid, deadline)
    end
  end
end
