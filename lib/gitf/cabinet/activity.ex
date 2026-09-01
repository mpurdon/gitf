defmodule GiTF.Cabinet.Activity do
  @moduledoc """
  The Cabinet's activity feed: operator acts (wake, stop, mode change,
  start-this, registry edits) and notable system results, newest first.
  Deliveries themselves live in the inbox; this is everything DONE about
  them and to the fleet — time · actor · action · target · result.
  """

  alias GiTF.Archive

  @collection :cabinet_activity
  @keep 200

  def record(actor, action, target, result \\ nil) do
    {:ok, entry} =
      Archive.insert(@collection, %{
        actor: to_string(actor),
        action: to_string(action),
        target: to_string(target),
        result: result && to_string(result),
        at: DateTime.utc_now()
      })

    prune()
    entry
  end

  @doc "Newest first."
  def list(limit \\ 30) do
    @collection
    |> Archive.all()
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  defp prune do
    entries = Archive.all(@collection)

    if length(entries) > @keep do
      entries
      |> Enum.sort_by(& &1.at, {:desc, DateTime})
      |> Enum.drop(@keep)
      |> Enum.each(&Archive.delete(@collection, &1.id))
    end
  end
end
