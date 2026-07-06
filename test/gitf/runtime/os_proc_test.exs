defmodule GiTF.Runtime.OsProcTest do
  use ExUnit.Case, async: true

  alias GiTF.Runtime.OsProc

  # Spawn a real, long-lived OS process detached from the BEAM and return its
  # pid as a string (mirrors how a detached ghost pid is captured).
  defp spawn_sleeper do
    port = Port.open({:spawn, "sleep 300 & echo $!"}, [:binary, :exit_status])

    pid =
      receive do
        {^port, {:data, data}} -> String.trim(data)
      after
        2_000 -> flunk("sleeper did not report pid")
      end

    # Drain the shell's exit; the backgrounded sleep keeps running.
    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      2_000 -> :ok
    end

    pid
  end

  describe "port_pid/1" do
    test "returns the OS pid of a spawned executable port" do
      cat = System.find_executable("cat")
      port = Port.open({:spawn_executable, cat}, [:binary, :exit_status])

      assert is_integer(OsProc.port_pid(port))

      Port.close(port)
    end

    test "returns nil for a non-port" do
      assert OsProc.port_pid(:not_a_port) == nil
    end
  end

  describe "terminate/2" do
    test "kills a live detached OS process" do
      pid = spawn_sleeper()
      assert OsProc.alive?(pid)

      assert :ok = OsProc.terminate(pid, grace_ms: 500)

      # SIGTERM should stop `sleep` promptly; give the OS a beat.
      Process.sleep(200)
      refute OsProc.alive?(pid)
    end

    test "is a no-op for nil / already-dead / garbage pids" do
      assert :ok = OsProc.terminate(nil, [])
      assert :ok = OsProc.terminate("not-a-number", [])
      assert :ok = OsProc.terminate(2_147_483_646, grace_ms: 100)
    end
  end

  describe "alive?/1" do
    test "false for nil and non-numeric strings" do
      refute OsProc.alive?(nil)
      refute OsProc.alive?("nope")
    end

    test "true for our own OS pid" do
      own = System.pid() |> String.to_integer()
      assert OsProc.alive?(own)
    end
  end
end
