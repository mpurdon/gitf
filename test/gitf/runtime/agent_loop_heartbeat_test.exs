defmodule GiTF.Runtime.AgentLoopHeartbeatTest do
  @moduledoc """
  Unit tests for the heartbeat path in `GiTF.Runtime.AgentLoop.wait_for_llm/3`.

  Regression: gemini-2.5-pro with extended thinking silently deliberates >120s
  before emitting any stream/progress events, which the ghost worker
  misdiagnoses as a hang and kills (`stale_threshold_seconds`). The heartbeat
  keeps the worker's `last_activity_at` fresh while the blocking
  `LLMClient.generate_text/3` is in flight, letting slow-but-working calls
  succeed while still catching genuine hangs via the same 120s threshold.
  """
  use ExUnit.Case, async: true

  alias GiTF.Runtime.AgentLoop

  defp collector do
    parent = self()
    {fn event -> send(parent, {:progress, event}) end, parent}
  end

  test "returns fast-path result without emitting heartbeats" do
    {on_progress, _} = collector()

    task = Task.async(fn -> {:ok, :done} end)
    result = AgentLoop.wait_for_llm(task, on_progress, 50)

    assert result == {:ok, :done}
    refute_received {:progress, %{type: :heartbeat}}
  end

  test "emits heartbeats while the task is still running" do
    {on_progress, _} = collector()

    # Periodicity needs >= 2 heartbeats, but a 110ms window at a 30ms
    # interval leaves only ~3 ticks of headroom — under full-suite load the
    # scheduler ate one often enough to fail intermittently and cost real
    # diagnostic time. A wider window buys ~10 expected ticks for the same
    # assertion, so jitter no longer decides the outcome.
    task =
      Task.async(fn ->
        Process.sleep(400)
        {:ok, :finished}
      end)

    result = AgentLoop.wait_for_llm(task, on_progress, 30)

    assert result == {:ok, :finished}

    heartbeats =
      for _ <- 1..30, reduce: 0 do
        acc ->
          receive do
            {:progress, %{type: :heartbeat}} -> acc + 1
          after
            0 -> acc
          end
      end

    assert heartbeats >= 2,
           "expected at least 2 heartbeats during ~400ms sleep at 30ms interval, got #{heartbeats}"
  end

  test "propagates LLMClient {:error, reason} unchanged — no wrapping" do
    {on_progress, _} = collector()

    task = Task.async(fn -> {:error, :timeout} end)
    assert {:error, :timeout} = AgentLoop.wait_for_llm(task, on_progress, 50)
  end

  test "surfaces task crashes as {:error, {:task_exit, reason}}" do
    {on_progress, _} = collector()

    # Trap exits so Task.async's link doesn't crash this test process when
    # the task's exit propagates. Without this, the `raise` below would
    # terminate the test runner because Task.async links the task to us.
    Process.flag(:trap_exit, true)

    task = Task.async(fn -> raise "boom" end)
    assert {:error, {:task_exit, _reason}} = AgentLoop.wait_for_llm(task, on_progress, 50)

    # Drain the linked-exit message so subsequent tests aren't affected.
    receive do
      {:EXIT, _pid, _reason} -> :ok
    after
      100 -> :ok
    end
  end

  test "heartbeat omitted cleanly when on_progress is nil" do
    # AgentLoop allows on_progress to be nil. Ensure wait_for_llm handles
    # that without crashing when a heartbeat tick fires.
    task =
      Task.async(fn ->
        Process.sleep(80)
        {:ok, :ok}
      end)

    assert {:ok, :ok} = AgentLoop.wait_for_llm(task, nil, 20)
  end
end
