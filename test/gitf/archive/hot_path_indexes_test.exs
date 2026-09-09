defmodule GiTF.Archive.HotPathIndexesTest do
  @moduledoc """
  Execution-efficiency B2: the folds that ran every few seconds — the
  watchdog's spend sum, the spawn gate's working-ghost count, the
  Major's unread-link recovery — read indexes now, and the answers must
  be the ones the scans gave.
  """
  use GiTF.StoreCase

  alias GiTF.{Archive, Costs, Ghosts, Link}

  test "a mission's spend sums its ghosts' costs through the ghost_id index" do
    {:ok, m} = Archive.insert(:missions, %{name: "b2", status: "active"})
    {:ok, _} = Archive.insert(:ops, %{mission_id: m.id, ghost_id: "g-a", status: "done"})
    {:ok, _} = Archive.insert(:ops, %{mission_id: m.id, ghost_id: "g-b", status: "done"})

    for {g, usd} <- [{"g-a", 1.5}, {"g-b", 2.25}, {"g-other", 100.0}] do
      {:ok, _} =
        Archive.insert(:costs, %{
          ghost_id: g,
          cost_usd: usd,
          model: "m",
          input_tokens: 1,
          output_tokens: 1,
          recorded_at: DateTime.utc_now()
        })
    end

    assert Costs.total_for_missions([m.id]) == 3.75
    assert Costs.total_for_missions([]) == 0.0
  end

  test "working ghosts are counted, not listed and sorted" do
    {:ok, a} = Archive.insert(:ghosts, %{name: "a", status: "working"})
    {:ok, _} = Archive.insert(:ghosts, %{name: "b", status: "stopped"})
    n = Ghosts.count("working")
    assert n >= 1
    assert Enum.any?(Ghosts.list(status: "working"), &(&1.id == a.id))

    {:ok, _} = Archive.update(:ghosts, a.id, &Map.put(&1, :status, "stopped"))
    assert Ghosts.count("working") == n - 1
  end

  test "unread links for a recipient come from the unread_to index and leave it when read" do
    {:ok, w1} = Link.send("ghost-1", "major", "job_complete", "done")
    {:ok, w2} = Link.send("ghost-2", "major", "job_complete", "done")
    {:ok, _} = Link.send("major", "ghost-1", "work", "go")

    unread = Link.list(to: "major", read: false) |> Enum.map(& &1.id)
    assert w1.id in unread and w2.id in unread

    assert Archive.by_index(:links, :unread_to, "major") |> Enum.map(& &1.id) |> Enum.sort() ==
             Enum.sort(unread)

    {:ok, _} = Link.mark_read(w1.id)
    assert Link.list(to: "major", read: false) |> Enum.map(& &1.id) == [w2.id]
    assert Archive.by_index(:links, :unread_to, "major") |> length() == 1
  end
end
