defmodule GiTF.Cabinet.Gate do
  @moduledoc """
  The activation decision: event in, one of wake / queue / drop out, and
  the action taken. Every failure anywhere in the chain — unknown
  ministry mode, invalid rules, unsupported JDM, classifier surprise —
  resolves to QUEUE. A wrongly queued event costs operator attention; a
  wrong wake costs money silently.
  """

  require Logger

  alias GiTF.Archive
  alias GiTF.Cabinet.{Classifier, Fleet, JDM, Registry}

  @inbox :cabinet_inbox

  @doc """
  Handles a verified webhook delivery for `ministry`. Returns
  `{:wake, inbox_entry} | {:queue, inbox_entry} | {:drop, class}`.
  Waking and forwarding run under the TaskSupervisor — GitHub gets its
  200 immediately.
  """
  def handle(ministry, event, payload, raw) do
    class = Classifier.classify(event, payload)

    case decide(ministry, class) do
      "drop" ->
        {:drop, class}

      "wake" ->
        entry = record(ministry, class, event, payload, "waking")
        start_forward(ministry, entry, raw)
        {:wake, entry}

      _queue ->
        {:queue, record(ministry, class, event, payload, "queued")}
    end
  end

  @doc "The ruleset verdict for `class` under the ministry's mode: \"wake\" | \"queue\" | \"drop\"."
  def decide(ministry, class) do
    input = %{
      "class" => to_string(class),
      "mode" => to_string(ministry[:mode] || "normal"),
      "over_cap" => over_cap?(ministry)
    }

    case JDM.evaluate(ministry[:rules] || JDM.default_rules(), input) do
      {:ok, %{"action" => action}} when action in ["wake", "queue", "drop"] ->
        action

      other ->
        Logger.warning(
          "Cabinet: ruleset for #{ministry[:slug]} did not decide (#{inspect(other)}) — queueing"
        )

        "queue"
    end
  end

  @doc "Starts a queued inbox entry: wake the Section, forward the event."
  def start_queued(entry_id) do
    with %{} = entry <- Archive.get(@inbox, entry_id),
         %{} = ministry <- Registry.by_slug(entry.ministry_slug) do
      Archive.update(@inbox, entry_id, &Map.put(&1, :status, "waking"))
      start_forward(ministry, entry, entry[:raw])
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "The inbox, newest first; `status: \"queued\"` is what the operator owes an answer."
  def inbox(slug \\ nil) do
    @inbox
    |> Archive.all()
    |> Enum.filter(&(slug == nil or &1.ministry_slug == slug))
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  # -- internals ---------------------------------------------------------------

  defp record(ministry, class, event, payload, status) do
    {:ok, entry} =
      Archive.insert(@inbox, %{
        ministry_slug: ministry.slug,
        class: to_string(class),
        event: event,
        summary: summarize(event, payload),
        status: status,
        raw: nil,
        inserted_at: DateTime.utc_now()
      })

    entry
  end

  defp start_forward(ministry, entry, raw) do
    Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
      result =
        with :ok <- Fleet.wake_and_await(ministry) do
          forward(ministry, entry, raw)
        end

      status = if result == :ok, do: "forwarded", else: "forward_failed"
      Archive.update(@inbox, entry.id, &Map.put(&1, :status, status))

      if result != :ok do
        Logger.warning(
          "Cabinet: forward to #{ministry.slug} failed (#{inspect(result)}) — " <>
            "the Section's events poller will reconcile on its next wake"
        )
      end
    end)
  end

  # The original body and signature pass through verbatim — the Section
  # verifies with the same per-ministry secret GitHub signed with. The
  # Cabinet never re-signs anything.
  defp forward(%{url: url}, entry, raw) when is_binary(url) and is_map(raw) do
    target = String.trim_trailing(url, "/") <> "/api/v1/webhooks/github"

    case Req.post(
           url: target,
           body: raw["body"],
           headers: raw["headers"],
           retry: false,
           receive_timeout: 15_000
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  after
    _ = entry
  end

  defp forward(_, _, _), do: {:error, :nothing_to_forward}

  defp over_cap?(%{cost_cap_usd: cap} = ministry) when is_number(cap) and cap > 0 do
    spend = ministry[:spend_month_usd] || 0.0
    spend >= cap
  end

  defp over_cap?(_), do: false

  defp summarize("issues", payload),
    do: "issue ##{get_in(payload, ["issue", "number"])}: #{get_in(payload, ["issue", "title"])}"

  defp summarize(event, payload) do
    repo = get_in(payload, ["repository", "full_name"]) || "?"
    "#{event} on #{repo}"
  end
end
