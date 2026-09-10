defmodule GiTF.Cabinet.Discord.Render do
  @moduledoc """
  Relayed events → Discord messages. Pure: maps in, maps out, no API.

  No LLM writes a notification. Every event is structured data and renders
  deterministically into an embed, and — where the operator can act — into
  components whose `custom_id` names exactly one factory tool call:

      <action>:<slug>:<entity_id>[:<arg>]

  `GiTF.Cabinet.Discord.Actions` is the other half of that contract: it
  parses the id back and runs the tool with the actor `discord:<user>`.
  A message renders the same on the phone and in the test, and a button
  that exists here is a tool that exists there — `custom_id/1` and
  `Actions.parse/1` are unit-tested against each other.

  Discord limits that shape this module: `custom_id` ≤ 100 chars, 5
  buttons per row, 25 select options, 2000 chars of content, 4096 of
  embed description, 25 embed fields.
  """

  @styles %{primary: 1, secondary: 2, success: 3, danger: 4, link: 5}

  # Discord's component type ids.
  @action_row 1
  @button 2
  @select 3

  @colors %{
    "critical" => 0xE5484D,
    "high" => 0xF76B15,
    "medium" => 0xFFC53D,
    "low" => 0x8B8D98,
    "ok" => 0x30A46C
  }

  @doc """
  Renders one relayed event for the ministry it came from. Returns
  `%{content: nil | String.t(), embeds: [map], components: [map]}`.
  """
  @spec render(map(), map()) :: %{content: String.t() | nil, embeds: [map()], components: [map()]}
  def render(event, ministry) do
    event = atomize(event)
    slug = ministry[:slug] || "?"

    %{
      content: nil,
      embeds: [embed(event, ministry)],
      components: components(event, slug)
    }
  end

  @doc "A row of `[label, custom_id, style]` triples → one action row of buttons."
  def buttons(specs) do
    %{
      type: @action_row,
      components:
        Enum.map(specs, fn
          {:link, label, url} ->
            %{type: @button, style: @styles.link, label: label, url: url}

          {label, custom_id, style} ->
            %{
              type: @button,
              style: Map.fetch!(@styles, style),
              label: label,
              custom_id: custom_id
            }
        end)
    }
  end

  @doc "A select menu whose values are option ids."
  def select(custom_id, placeholder, options) do
    %{
      type: @action_row,
      components: [
        %{
          type: @select,
          custom_id: custom_id,
          placeholder: String.slice(placeholder, 0, 150),
          options:
            options
            |> Enum.take(25)
            |> Enum.map(fn o ->
              %{
                label: String.slice(o[:label] || o[:id], 0, 100),
                value: String.slice(o[:id], 0, 100),
                description: o[:rationale] && String.slice(o[:rationale], 0, 100)
              }
              |> Enum.reject(fn {_, v} -> is_nil(v) end)
              |> Map.new()
            end)
        }
      ]
    }
  end

  @doc "Builds a custom_id and refuses one Discord would (over 100 chars)."
  @spec custom_id([String.t() | integer()]) :: String.t()
  def custom_id(parts) do
    id = Enum.map_join(parts, ":", &to_string/1)
    if String.length(id) > 100, do: raise(ArgumentError, "custom_id too long: #{id}"), else: id
  end

  @doc """
  The same message after someone acted on it: components disabled, and a
  line saying who did what — "answered by @matt 21:04" — so a second
  reader sees a decision, not a live question.
  """
  def settled(message, outcome_line) do
    message = plain(message)

    components =
      Enum.map(message[:components] || [], fn row ->
        Map.update(row, :components, [], fn cs -> Enum.map(cs, &Map.put(&1, :disabled, true)) end)
      end)

    embeds =
      case message[:embeds] || [] do
        [first | rest] -> [Map.put(first, :footer, %{text: outcome_line}) | rest]
        [] -> [%{description: outcome_line}]
      end

    %{content: message[:content], embeds: embeds, components: components}
  end

  # A message that came back from the gateway is Nostrum structs whose
  # every unset field is nil; Discord wants those absent, not null.
  @doc false
  def plain(%_{} = struct), do: struct |> Map.from_struct() |> plain()

  def plain(map) when is_map(map) do
    for {k, v} <- map, v != nil, into: %{}, do: {k, plain(v)}
  end

  def plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  def plain(other), do: other

  # -- Embeds ----------------------------------------------------------------

  defp embed(event, ministry) do
    base = %{
      title: title(event),
      description: description(event),
      color: color(event),
      timestamp: event[:at],
      footer: %{text: footer(event, ministry)}
    }

    case link(event) do
      nil -> base
      url -> Map.put(base, :url, url)
    end
    |> add_fields(fields(event))
  end

  defp title(%{type: "input_requested", data: d}),
    do: "Question · #{d[:mission_id]} · #{d[:phase]}"

  defp title(%{type: "input_stalled", data: d}), do: "Still waiting · #{d[:mission_id]}"
  defp title(%{type: "approval_requested", data: d}), do: "Approval · #{d[:mission_id]}"
  defp title(%{type: "idle_stop_imminent", data: d}), do: "Sleeping in ~#{d[:minutes_left]} min"
  defp title(%{type: "quest_failed", data: d}), do: "Failed · #{d[:mission_id]}"
  defp title(%{type: "mission_created", data: d}), do: "Mission #{d[:mission_id]} started"
  defp title(%{type: "mission_completed", data: d}), do: "Mission #{d[:mission_id]} completed"
  defp title(%{type: "inbox_queued", data: d}), do: "Queued · #{d[:class]} for #{d[:ministry]}"
  defp title(%{type: "fleet", data: d}), do: "#{d[:ministry]} #{d[:state]}"
  defp title(%{type: type}), do: humanize(type)

  defp description(%{type: "input_requested", data: %{prompt: prompt}}) when is_binary(prompt),
    do: String.slice(prompt, 0, 4000)

  defp description(%{type: "approval_requested", data: %{goal: goal}}) when is_binary(goal),
    do: String.slice(goal, 0, 4000)

  defp description(%{type: "quest_failed", data: %{reason: reason}}) when is_binary(reason),
    do: String.slice(reason, 0, 4000)

  defp description(%{type: "idle_stop_imminent", data: d}) do
    held =
      case d[:held_missions] do
        n when is_integer(n) and n > 0 -> "\n#{n} mission(s) are holding for you and will wait."
        _ -> ""
      end

    "Idle since #{short_time(d[:idle_since])}, powers off at #{short_time(d[:stop_at])}." <> held
  end

  defp description(%{type: "inbox_queued", data: d}), do: d[:summary] || ""

  defp description(%{message: message}) when is_binary(message),
    do: String.slice(message, 0, 4000)

  defp description(_), do: ""

  # Choice options are the substance of a question; each gets a field so
  # the rationale is readable before the menu is opened.
  defp fields(%{type: "input_requested", data: %{kind: kind, options: options}})
       when kind in ["choice", :choice] and is_list(options) do
    options
    |> Enum.take(25)
    |> Enum.map(fn o ->
      %{
        name: String.slice("#{o[:id]} — #{o[:label]}", 0, 256),
        value: String.slice(o[:rationale] || "—", 0, 1024),
        inline: false
      }
    end)
  end

  defp fields(%{type: "approval_requested", data: %{pr_url: url}}) when is_binary(url),
    do: [%{name: "Pull request", value: url, inline: false}]

  defp fields(%{type: "inbox_queued", data: d}) do
    [%{name: "Rule", value: to_string(d[:rule] || "fallback"), inline: true}]
  end

  defp fields(_), do: []

  defp add_fields(embed, []), do: embed
  defp add_fields(embed, fields), do: Map.put(embed, :fields, fields)

  defp color(%{type: "mission_completed"}), do: @colors["ok"]
  defp color(%{type: "fleet", data: %{state: "running"}}), do: @colors["ok"]
  defp color(%{severity: s}), do: Map.get(@colors, to_string(s), @colors["low"])
  defp color(_), do: @colors["low"]

  defp footer(event, ministry) do
    [ministry[:name] || ministry[:slug], event[:version] && "v#{event[:version]}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  # Deep link into the right Catwalk page for the thing the embed is about.
  defp link(%{url: url} = event) when is_binary(url) and url != "" do
    base = String.trim_trailing(url, "/")

    case event do
      %{type: "input_requested"} -> "#{base}/dashboard/questions"
      %{type: "input_stalled"} -> "#{base}/dashboard/questions"
      %{type: "approval_requested"} -> "#{base}/dashboard/approvals"
      %{data: %{mission_id: id}} when is_binary(id) -> "#{base}/dashboard/missions/#{id}"
      _ -> "#{base}/dashboard"
    end
  end

  defp link(_), do: nil

  # -- Components ------------------------------------------------------------

  defp components(%{type: "input_requested", data: %{kind: kind} = d}, slug)
       when kind in ["choice", :choice] do
    id = custom_id(["answer", slug, d[:inquiry_id]])
    options = Enum.map(d[:options] || [], &atomize/1)

    [
      select(id, "Choose an option", options),
      buttons([
        {"Reject all — propose again", custom_id(["reject_all", slug, d[:inquiry_id]]),
         :secondary}
      ])
    ]
  end

  defp components(%{type: "input_requested", data: %{kind: kind} = d}, slug)
       when kind in ["confirm", :confirm] do
    [
      buttons([
        {"Yes", custom_id(["answer", slug, d[:inquiry_id], "true"]), :success},
        {"No", custom_id(["answer", slug, d[:inquiry_id], "false"]), :danger}
      ])
    ]
  end

  # A :text question needs words, and words are M2 (the agent). Until then
  # the button is a link to where the words go.
  defp components(%{type: "input_requested", url: url}, _slug) when is_binary(url),
    do: [
      buttons([
        {:link, "Answer on the Catwalk", String.trim_trailing(url, "/") <> "/dashboard/questions"}
      ])
    ]

  defp components(%{type: "input_requested"}, _slug), do: []

  defp components(%{type: "approval_requested", data: d}, slug) do
    [
      buttons([
        {"Approve", custom_id(["approve", slug, d[:mission_id]]), :success},
        {"Reject", custom_id(["reject", slug, d[:mission_id]]), :danger}
      ])
    ]
  end

  defp components(%{type: "idle_stop_imminent"}, slug) do
    [
      buttons([
        {"Keep awake 1h", custom_id(["hold", slug, 60]), :primary},
        {"Keep awake 4h", custom_id(["hold", slug, 240]), :primary},
        {"Sleep now", custom_id(["sleep", slug]), :secondary}
      ])
    ]
  end

  defp components(%{type: "quest_failed", data: d}, slug) do
    [buttons([{"Resume", custom_id(["resume", slug, d[:mission_id]]), :secondary}])]
  end

  defp components(%{type: "inbox_queued", data: d}, _slug) do
    [
      buttons([
        {"Start", custom_id(["inbox_start", d[:entry_id]]), :primary},
        {"Drop", custom_id(["inbox_drop", d[:entry_id]]), :secondary}
      ])
    ]
  end

  defp components(%{type: "fleet", data: %{state: "stopped"}}, slug),
    do: [buttons([{"Wake", custom_id(["wake", slug]), :primary}])]

  defp components(_, _), do: []

  # -- Helpers ---------------------------------------------------------------

  defp humanize(type), do: type |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp short_time(nil), do: "?"

  defp short_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M UTC")
      _ -> iso
    end
  end

  # Relayed JSON arrives with string keys; the renderer pattern-matches on
  # atoms. Only known keys are atomized, so an unexpected field cannot
  # grow the atom table.
  @keys ~w(kind type severity message data mission_id at version url inquiry_id phase prompt
           options id label rationale goal pr_url stop_at idle_since minutes_left held_missions
           reason name entry_id class ministry summary rule state)a

  defp atomize(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) ->
        atom = Enum.find(@keys, &(Atom.to_string(&1) == k))
        {atom || k, atomize(v)}

      {k, v} ->
        {k, atomize(v)}
    end)
  end

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(other), do: other
end
