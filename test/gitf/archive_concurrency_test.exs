defmodule GiTF.ArchiveConcurrencyTest do
  @moduledoc """
  Exercises the redesigned Archive write path: lock-free concurrent inserts,
  per-collection serialized read-modify-write, and asynchronous persistence.
  """
  use ExUnit.Case, async: false

  alias GiTF.Archive

  setup do
    tmp = Path.join(System.tmp_dir!(), "gitf_arch_conc_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = Archive.start_link(data_dir: tmp)

    on_exit(fn ->
      GiTF.Test.StoreHelper.stop_store()
      File.rm_rf(tmp)
    end)

    %{tmp: tmp}
  end

  test "concurrent inserts are all retained (lock-free, no lost writes)" do
    n = 500
    # :runs isn't written by the telemetry handler (unlike :events), so the
    # count is deterministic.
    1..n
    |> Task.async_stream(fn i -> Archive.insert(:runs, %{id: "run-#{i}", n: i}) end,
      max_concurrency: 50,
      timeout: 10_000
    )
    |> Stream.run()

    assert Archive.count(:runs) == n
  end

  test "concurrent updates to the SAME record serialize (no lost increments)" do
    {:ok, rec} = Archive.insert(:model_scores, %{count: 0})
    id = rec.id
    n = 200

    1..n
    |> Task.async_stream(
      fn _ ->
        Archive.update(:model_scores, id, fn r -> %{r | count: r.count + 1} end)
      end,
      max_concurrency: 50,
      timeout: 10_000
    )
    |> Stream.run()

    # If RMW weren't serialized per collection, increments would be lost.
    assert Archive.get(:model_scores, id).count == n
  end

  test "writes to different collections proceed independently" do
    tasks =
      for col <- [:events, :model_scores, :debriefs, :runs] do
        Task.async(fn ->
          for i <- 1..100, do: Archive.insert(col, %{id: "#{col}-#{i}", i: i})
          Archive.count(col)
        end)
      end

    counts = Task.await_many(tasks, 10_000)
    assert Enum.all?(counts, &(&1 == 100))
  end

  test "flush/0 persists all dirty collections to disk", %{tmp: tmp} do
    {:ok, _} = Archive.insert(:events, %{id: "e1"})
    {:ok, _} = Archive.insert(:runs, %{id: "r1"})

    # Async: nothing on disk yet.
    refute File.exists?(Path.join(tmp, "events.etf"))

    assert :ok = Archive.flush()
    assert File.exists?(Path.join(tmp, "events.etf"))
    assert File.exists?(Path.join(tmp, "runs.etf"))
  end
end
