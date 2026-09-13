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

  @doc """
  Records one act.

  `target` is free text — a slug, an issue title, "home-affairs rule 3" — so it
  cannot in general be read back as a ministry. `ministry` says which ministry
  the act was about, and is what the Console groups and filters by.

  Most acts pass the slug as the target, so it is derived from there when not
  given; pass it explicitly whenever the target is something else. Anything not
  slug-shaped is recorded as no ministry rather than as a wrong one — a
  dismissed issue's title once appeared in the Console's ministry facet as
  though it were a ministry.
  """
  def record(actor, action, target, result \\ nil, ministry \\ nil) do
    target = to_string(target)

    {:ok, entry} =
      Archive.insert(@collection, %{
        actor: to_string(actor),
        action: to_string(action),
        target: target,
        result: result && to_string(result),
        ministry: slug(ministry || target),
        at: DateTime.utc_now()
      })

    prune()
    # Listeners (the Discord bot's #cabinet feed) get the entry as written.
    Phoenix.PubSub.broadcast(GiTF.PubSub, "cabinet:activity", {:cabinet_activity, entry})
    entry
  end

  @doc "Newest first."
  def list(limit \\ 30) do
    @collection
    |> Archive.all()
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  # A slug or nothing. Trailing whitespace has reached this field before, and a
  # slug that differs from another only by a space reads as two ministries.
  defp slug(nil), do: nil

  defp slug(value) do
    trimmed = value |> to_string() |> String.trim()
    if trimmed =~ ~r/^[a-z0-9][a-z0-9-]*$/, do: trimmed
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
