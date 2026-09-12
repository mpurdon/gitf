defmodule GiTF.Dashboard.Console.Format do
  @moduledoc """
  Every phrase the Console puts on screen about a ministry, in one place.

  Presentation was scattered through the old console as private helpers next to
  the markup that used it, which is how the same action ended up labelled
  `Sleep` in one place and `Stop factory` in another, and how spend came to be
  printed beside a cap it was not measured against. Pure functions over a
  registry record: no I/O, so they are cheap to call in a render and easy to
  test without one.
  """

  alias GiTF.Cabinet.JDM

  @doc "EC2's word for the box, or nil when the Cabinet has never looked."
  def box_state(m), do: get_in(m, [:box, :state])

  def running?(m), do: box_state(m) == "running"

  @doc "The dot beside a ministry. nil is the common case — colour has to mean something."
  def state_tone(m) do
    case box_state(m) do
      "running" -> :ok
      "pending" -> :recon
      "stopping" -> :recon
      _ -> nil
    end
  end

  @doc "What to call the state in a pill."
  def state_label(m) do
    case box_state(m) do
      "running" -> "running"
      "pending" -> "waking"
      "stopping" -> "stopping"
      "stopped" -> "asleep"
      nil -> if m[:instance_id], do: "unseen", else: "no factory"
      other -> to_string(other)
    end
  end

  @doc """
  How long it has been this way.

  Awake → the daemon's own uptime, because the box can boot a minute before the
  release comes up. Asleep → since the Cabinet saw it stop, which is the best
  anyone has: EC2 keeps a launch time and forgets the stop.
  """
  def state_for(m) do
    live = m[:live]
    since = get_in(m, [:box, :state_since])

    cond do
      is_map(live) and is_integer(live["uptime_seconds"]) -> "up #{dur(live["uptime_seconds"])}"
      running?(m) and since -> "up #{ago(since)} (EC2)"
      box_state(m) == "stopped" and since -> "asleep #{ago(since)}"
      box_state(m) == "stopped" -> "asleep since before the Cabinet watched"
      box_state(m) in ["pending", "stopping"] and since -> "for #{ago(since)}"
      true -> "—"
    end
  end

  @doc "When it powers itself off, or what is keeping it up."
  def sleeps_in(%{live: live} = m) when is_map(live) do
    cond do
      live["idle"] != true ->
        "held awake — #{live["active_missions"] || 0} missions · #{live["active_ghosts"] || 0} ghosts"

      is_binary(live["idle_stop_at"]) ->
        case DateTime.from_iso8601(live["idle_stop_at"]) do
          {:ok, at, _} -> "sleeps in #{until(at)}"
          _ -> "idle"
        end

      true ->
        "idle · idle-stop not scheduled"
    end
    |> then(fn s -> if running?(m), do: s, else: "—" end)
  end

  def sleeps_in(m), do: if(running?(m), do: "running, health unreachable", else: "—")

  def version(%{live: live}) when is_map(live), do: live["version"] || "—"
  def version(_), do: "—"

  def load(%{live: live}) when is_map(live),
    do: "#{live["active_missions"] || 0} missions · #{live["active_ghosts"] || 0} ghosts"

  def load(_), do: "—"

  def observed_at(m) do
    case get_in(m, [:box, :state_since]) do
      %DateTime{} = at -> "#{ago(at)} ago"
      _ -> "never"
    end
  end

  def live_at(%{live_at: %DateTime{} = at}), do: "#{ago(at)} ago"
  def live_at(_), do: "no answer stored"

  @doc """
  Spend, against the cap that actually gates a wake.

  The old console printed `spend_usd` — a retention-bounded lifetime total —
  next to `cost_cap_usd`, which the Gate enforces against month-to-date. Two
  different numbers, one comparison, and the monthly figure was never shown.
  """
  def spend_line(m) do
    case {m[:spend_month_usd], m[:cost_cap_usd]} do
      {nil, _} -> "no snapshot yet"
      {spend, nil} -> "#{money(spend)} this month · no cap"
      {spend, cap} -> "#{money(spend)} of #{money(cap)} this month"
    end
  end

  def cap_state(m) do
    case {m[:spend_month_usd], m[:cost_cap_usd]} do
      {_, nil} -> "no cap — nothing gates a wake"
      {nil, cap} -> "capped at #{money(cap)} · no spend recorded yet"
      {spend, cap} when spend >= cap -> "over the cap — wakes become queues"
      {_, _} -> "under the cap"
    end
  end

  def cap_tone(m) do
    case {m[:spend_month_usd], m[:cost_cap_usd]} do
      {_, nil} -> :warn
      {spend, cap} when is_number(spend) and spend >= cap -> :crit
      _ -> :ok
    end
  end

  def money(nil), do: "—"
  def money(n) when is_number(n), do: "$" <> :erlang.float_to_binary(n / 1, decimals: 2)
  def money(_), do: "—"

  # -- activations -----------------------------------------------------------

  @doc "Why an activation went the way it did, in one line."
  def decision_line(entry) do
    d = entry[:decision] || %{}
    action = d[:action] || entry[:status]
    rule = if d[:rule], do: " · rule #{d[:rule]}", else: ""
    "#{entry[:class]} under #{d[:mode] || "?"} → #{action}#{rule}"
  end

  def status_tone(status) do
    case status do
      "queued" -> :warn
      "waking" -> :recon
      "forwarded" -> :ok
      "forward_failed" -> :crit
      _ -> nil
    end
  end

  def action_tone("wake"), do: :ok
  def action_tone("queue"), do: :warn
  def action_tone("drop"), do: nil
  def action_tone(_), do: nil

  def queued(inbox), do: Enum.filter(inbox, &(&1[:status] == "queued"))

  @doc """
  The inbox filters.

  `dropped` is gone on purpose: `Gate.handle` returns `{:drop, class}` without
  writing a record, so nothing anywhere sets that status and the filter could
  only ever show dismissed items. A filter that cannot match is worse than no
  filter, because it reads as proof that nothing was dropped.
  """
  def inbox_filters,
    do: [{"all", "all"}, {"waiting", "waiting"}, {"woke", "woke"}, {"dismissed", "dismissed"}]

  def filter_inbox(inbox, "waiting"), do: queued(inbox)

  def filter_inbox(inbox, "woke"),
    do: Enum.filter(inbox, &(&1[:status] in ["waking", "forwarded", "forward_failed"]))

  def filter_inbox(inbox, "dismissed"), do: Enum.filter(inbox, &(&1[:status] == "dismissed"))
  def filter_inbox(inbox, _), do: inbox

  # -- ruleset ---------------------------------------------------------------

  def ruleset_summary(m) do
    rows = rule_rows(m)
    wake = Enum.count(rows, &(&1.action == "wake"))
    "#{length(rows)} rules · #{wake} of them wake a factory"
  end

  @doc "A ministry's decision table as rows, or [] when it is not one."
  def rule_rows(m) do
    doc = m[:rules] || JDM.default_rules()

    with %{"nodes" => nodes} <- doc,
         %{"content" => %{"rules" => rules} = content} <-
           Enum.find(nodes, &(&1["type"] == "decisionTableNode")) do
      # A JDM rule keys its cells by the input's or output's *id*, and quotes
      # the values: %{"i-class" => "\"bug\"", "o-action" => "\"wake\""}. Reading
      # `rule["action"]` finds nothing at all — quietly, which is how a rules
      # table renders six rows of dashes and still looks like it works.
      columns = (content["inputs"] || []) ++ (content["outputs"] || [])

      rules
      |> Enum.with_index(1)
      |> Enum.map(fn {rule, n} ->
        %{
          n: n,
          class: cell(rule, columns, "class"),
          mode: cell(rule, columns, "mode"),
          cap: cell(rule, columns, "over_cap"),
          action: cell(rule, columns, "action", "—")
        }
      end)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  defp cell(rule, columns, field, blank \\ "any") do
    id = Enum.find_value(columns, fn c -> if c["field"] == field, do: c["id"] end)

    (rule[id] || rule[field] || "")
    |> to_string()
    |> String.replace(~r/["']/, "")
    |> String.trim()
    |> case do
      "" -> blank
      v -> v |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.join(" · ")
    end
  end

  # -- clocks ----------------------------------------------------------------

  def hhmm(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M") <> "Z"
  def hhmm(_), do: "—"

  def dur(s) when is_integer(s) and s < 60, do: "#{s}s"
  def dur(s) when is_integer(s) and s < 3_600, do: "#{div(s, 60)}m"
  def dur(s) when is_integer(s) and s < 86_400, do: "#{div(s, 3_600)}h #{rem(div(s, 60), 60)}m"
  def dur(s) when is_integer(s), do: "#{div(s, 86_400)}d #{rem(div(s, 3_600), 24)}h"
  def dur(_), do: "—"

  def ago(%DateTime{} = dt), do: dur(max(DateTime.diff(DateTime.utc_now(), dt), 0))
  def ago(_), do: "—"

  def until(%DateTime{} = dt), do: dur(max(DateTime.diff(dt, DateTime.utc_now()), 0))
  def until(_), do: "—"
end
