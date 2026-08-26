defmodule GiTF.WorktreeLockTest do
  use ExUnit.Case, async: true

  alias GiTF.WorktreeLock

  test "returns the function's result" do
    assert WorktreeLock.with_lock({:sector, "sec-test-ret"}, fn -> {:ok, 42} end) == {:ok, 42}
  end

  test "same-key sections are mutually exclusive" do
    # Two tasks contend for one key; each records enter/leave. If the lock
    # holds, no section may begin before the previous one ends.
    parent = self()

    tasks =
      for i <- 1..4 do
        Task.async(fn ->
          WorktreeLock.with_lock({:sector, "sec-test-mutex"}, fn ->
            send(parent, {:enter, i})
            Process.sleep(30)
            send(parent, {:leave, i})
          end)
        end)
      end

    Enum.each(tasks, &Task.await(&1, 5_000))

    events =
      for _ <- 1..8 do
        receive do
          e -> e
        after
          0 -> flunk("missing lock event")
        end
      end

    # Strictly alternating enter/leave — never two enters in a row.
    {_, ok} =
      Enum.reduce(events, {nil, true}, fn
        {:enter, _}, {nil, ok} -> {:in, ok}
        {:leave, _}, {:in, ok} -> {nil, ok}
        _, {_, _} -> {nil, false}
      end)

    assert ok, "lock sections overlapped: #{inspect(events)}"
  end

  test "different keys do not serialize against each other" do
    t =
      Task.async(fn ->
        WorktreeLock.with_lock({:sector, "sec-a"}, fn ->
          WorktreeLock.with_lock({:sector, "sec-b"}, fn -> :nested_ok end)
        end)
      end)

    assert Task.await(t, 5_000) == :nested_ok
  end
end
