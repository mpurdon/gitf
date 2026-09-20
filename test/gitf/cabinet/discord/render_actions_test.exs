defmodule GiTF.Cabinet.Discord.RenderActionsTest do
  @moduledoc """
  The button contract: every `custom_id` `Render` mints, `Actions` parses
  back to the one operation it names. A button that renders but cannot
  be acted on is a phone that shows a question with no way to answer it.
  """
  use ExUnit.Case, async: true

  alias GiTF.Cabinet.Discord.{Actions, Render}

  @ministry %{slug: "home-affairs", name: "Home Affairs"}

  defp relayed(type, severity, data, extra \\ %{}) do
    Map.merge(
      %{
        "kind" => "alert",
        "type" => type,
        "severity" => severity,
        "message" => "#{type} happened",
        "data" => data,
        "mission_id" => data["mission_id"],
        "at" => "2026-09-10T01:02:03Z",
        "version" => "0.65.331",
        "url" => "https://factory.example"
      },
      extra
    )
  end

  # Walk every component the message carries and return its custom_ids.
  defp custom_ids(%{components: rows}) do
    for row <- rows, c <- row.components, id = c[:custom_id], is_binary(id), do: id
  end

  test "a choice question renders a select over the option ids, and each answer parses" do
    event =
      relayed("input_requested", "critical", %{
        "mission_id" => "msn-1",
        "inquiry_id" => "inq-abc",
        "kind" => "choice",
        "phase" => "design",
        "prompt" => "Which layout?",
        "options" => [
          %{"id" => "grid", "label" => "Grid", "rationale" => "denser"},
          %{"id" => "list", "label" => "List", "rationale" => "scannable"}
        ]
      })

    message = Render.render(event, @ministry)

    [embed] = message.embeds
    assert embed.title == "Question · msn-1 · design"
    assert embed.description == "Which layout?"
    assert embed.url == "https://factory.example/dashboard/questions"
    assert [%{name: "grid — Grid", value: "denser"}, %{name: "list — List"}] = embed.fields

    [select_row, reject_row] = message.components
    [select] = select_row.components
    assert select.custom_id == "answer:home-affairs:inq-abc"
    assert Enum.map(select.options, & &1.value) == ["grid", "list"]

    assert {:ok, {:answer, "home-affairs", "inq-abc", "list"}} =
             Actions.parse(select.custom_id, ["list"])

    # No pick yet is not an answer.
    assert {:ok, {:answer, _, _, nil}} = Actions.parse(select.custom_id, [])

    assert {:error, "pick an option first"} =
             Actions.perform({:answer, "x", "y", nil}, "discord:m")

    [reject] = reject_row.components
    assert {:ok, {:reject_all, "home-affairs", "inq-abc"}} = Actions.parse(reject.custom_id)
  end

  test "a confirm question is two buttons whose answers are booleans" do
    event =
      relayed("input_requested", "critical", %{
        "mission_id" => "msn-1",
        "inquiry_id" => "inq-c",
        "kind" => "confirm",
        "prompt" => "Ship it?"
      })

    ids = event |> Render.render(@ministry) |> custom_ids()
    assert ids == ["answer:home-affairs:inq-c:true", "answer:home-affairs:inq-c:false"]
    assert {:ok, {:answer, "home-affairs", "inq-c", true}} = Actions.parse(hd(ids))
    assert {:ok, {:answer, "home-affairs", "inq-c", false}} = Actions.parse(List.last(ids))
  end

  test "a text question has no button to answer with — only a link to the Catwalk" do
    event =
      relayed("input_requested", "critical", %{
        "mission_id" => "msn-1",
        "inquiry_id" => "inq-t",
        "kind" => "text",
        "prompt" => "Name the feature flag"
      })

    message = Render.render(event, @ministry)
    assert custom_ids(message) == []
    [%{components: [link]}] = message.components
    assert link.style == 5 and link.url =~ "/dashboard/questions"
  end

  test "an approval is approve / reject on the mission" do
    event =
      relayed("approval_requested", "critical", %{
        "mission_id" => "msn-9",
        "goal" => "add dark mode",
        "pr_url" => "https://github.com/o/r/pull/3"
      })

    message = Render.render(event, @ministry)

    assert [%{name: "Pull request", value: "https://github.com/o/r/pull/3"}] =
             hd(message.embeds).fields

    assert [{:ok, {:approve, "home-affairs", "msn-9"}}, {:ok, {:reject, "home-affairs", "msn-9"}}] =
             message |> custom_ids() |> Enum.map(&Actions.parse/1)
  end

  test "a sleep warning offers bounded holds and sleep-now" do
    event =
      relayed("idle_stop_imminent", "high", %{
        "stop_at" => "2026-09-10T01:12:00Z",
        "idle_since" => "2026-09-10T00:42:00Z",
        "minutes_left" => 9,
        "held_missions" => 1
      })

    message = Render.render(event, @ministry)
    embed = hd(message.embeds)

    # No countdown in the title: an embed title cannot carry a Discord
    # timestamp, so a baked-in "~9 min" is wrong a minute later and reads
    # "~0 min" forever after.
    assert embed.title == "Sleeping soon"
    refute embed.title =~ "min"

    # The live figure goes in the description, where Discord expands it in
    # the reader's own timezone and keeps it counting.
    assert embed.description =~ "<t:#{DateTime.to_unix(~U[2026-09-10 01:12:00Z])}:R>"
    assert embed.description =~ "<t:#{DateTime.to_unix(~U[2026-09-10 00:42:00Z])}:t>"
    refute embed.description =~ "UTC"

    assert embed.description =~ "One mission is holding"
    refute embed.description =~ "mission(s)"

    assert [
             {:ok, {:hold, "home-affairs", 60}},
             {:ok, {:hold, "home-affairs", 240}},
             {:ok, {:sleep, "home-affairs"}}
           ] = message |> custom_ids() |> Enum.map(&Actions.parse/1)
  end

  test "a queued inbox entry is start / drop, handled by the Cabinet itself" do
    event = %{
      "kind" => "cabinet",
      "type" => "inbox_queued",
      "severity" => "medium",
      "data" => %{
        "entry_id" => "gtf-e1",
        "ministry" => "home-affairs",
        "class" => "feature",
        "summary" => "issue #12: Add dark mode",
        "rule" => 3
      },
      "at" => "2026-09-10T01:02:03Z"
    }

    message = Render.render(event, %{slug: "cabinet", name: "Cabinet"})
    assert hd(message.embeds).title == "Queued · feature for home-affairs"

    assert [{:ok, {:inbox_start, "gtf-e1"}}, {:ok, {:inbox_drop, "gtf-e1"}}] =
             message |> custom_ids() |> Enum.map(&Actions.parse/1)
  end

  test "a failure offers resume; a stopped box offers wake" do
    failed = relayed("quest_failed", "high", %{"mission_id" => "msn-f", "reason" => "boom"})

    assert [{:ok, {:resume, "home-affairs", "msn-f"}}] =
             failed |> Render.render(@ministry) |> custom_ids() |> Enum.map(&Actions.parse/1)

    stopped = %{
      "kind" => "cabinet",
      "type" => "fleet",
      "severity" => "low",
      "data" => %{"ministry" => "home-affairs", "state" => "stopped"}
    }

    assert [{:ok, {:wake, "home-affairs"}}] =
             stopped |> Render.render(@ministry) |> custom_ids() |> Enum.map(&Actions.parse/1)
  end

  test "an unknown or malformed custom_id is refused, not guessed" do
    assert {:error, :unknown_action} = Actions.parse("delete_everything:home-affairs")
    assert {:error, :unknown_action} = Actions.parse("hold:home-affairs:lots")
    assert {:error, :unknown_action} = Actions.parse("hold:home-affairs:-5")
  end

  test "custom_ids stay within Discord's 100-char limit" do
    assert_raise ArgumentError, fn ->
      Render.custom_id(["answer", String.duplicate("s", 60), String.duplicate("i", 60)])
    end
  end

  test "a settled message disables every component and records who acted" do
    event = relayed("approval_requested", "critical", %{"mission_id" => "msn-9", "goal" => "x"})
    settled = event |> Render.render(@ministry) |> Render.settled("approved by @matt")
    embed = hd(settled.embeds)

    assert Enum.all?(settled.components, fn row -> Enum.all?(row.components, & &1.disabled) end)
    assert embed.footer.text =~ "approved by @matt"
  end

  test "settling keeps the identity that says which box it was about" do
    # A fleet message that has lost "Home Affairs · v..." no longer says
    # which box was acted on, and the outcome line alone does not tell you.
    event = relayed("approval_requested", "critical", %{"mission_id" => "msn-9", "goal" => "x"})
    rendered = Render.render(event, @ministry)
    identity = hd(rendered.embeds).footer.text

    settled = Render.settled(rendered, "approved by @matt")

    assert hd(settled.embeds).footer.text == "approved by @matt · " <> identity
    assert hd(settled.embeds).footer.text =~ "Home Affairs"
  end

  test "settling an idle warning rewrites the heading and body it just made false" do
    # The bug this exists for: tapping "Keep awake 4h" left a message headed
    # "Sleeping in ~0 min" over a body naming the power-off time, under a
    # footer saying it had been kept awake for 240 minutes. Two thirds of it
    # was false and the reader could not tell whether the box was awake.
    event =
      relayed("idle_stop_imminent", "high", %{
        "stop_at" => "2026-09-10T01:12:00Z",
        "idle_since" => "2026-09-10T00:42:00Z",
        "minutes_left" => 0
      })

    rendered = Render.render(event, @ministry)

    settled =
      Render.settled(rendered, "kept awake by @matt", Actions.resolved({:hold, "ha", 240}))

    embed = hd(settled.embeds)

    assert embed.title == "Staying awake"
    assert embed.description =~ "Awake for at least 4 hours"
    refute embed.description =~ "Powers off"
    refute embed.description =~ "Idle since"

    # "at least", never a flat promise of the asked-for duration:
    # IdleStop.hold/2 keeps a longer existing hold, so naming 1 hour while
    # four are already held would be false in exactly the case that guard
    # exists for. "another" would be wrong too — holds replace, not stack.
    refute embed.description =~ "another"
  end

  test "a failed act leaves the heading and body alone" do
    # Nothing happened, so the original warning is still the truth.
    event =
      relayed("idle_stop_imminent", "high", %{
        "stop_at" => "2026-09-10T01:12:00Z",
        "idle_since" => "2026-09-10T00:42:00Z"
      })

    rendered = Render.render(event, @ministry)
    settled = Render.settled(rendered, "could not: timed out", [])

    assert hd(settled.embeds).title == "Sleeping soon"
    assert hd(settled.embeds).description =~ "Powers off"
  end

  test "the settled timestamp moves to now, so one moment is shown once" do
    event = relayed("approval_requested", "critical", %{"mission_id" => "msn-9", "goal" => "x"})
    rendered = Render.render(event, @ministry)

    settled = Render.settled(rendered, "approved by @matt")

    refute hd(settled.embeds).timestamp == hd(rendered.embeds).timestamp
    {:ok, at, _} = DateTime.from_iso8601(hd(settled.embeds).timestamp)
    assert DateTime.diff(DateTime.utc_now(), at) < 5

    # And no second time of our own in the footer, in a different zone from
    # the one Discord renders beneath it.
    refute hd(settled.embeds).footer.text =~ "UTC"
  end

  test "resolved/1 only rewrites the acts that make the wording false" do
    assert Actions.resolved({:hold, "ha", 60})[:title] == "Staying awake"
    assert Actions.resolved({:sleep, "ha"})[:title] == "Asleep"
    assert Actions.resolved({:wake, "ha"})[:title] == "Awake"

    # An approval's body is the mission goal — still true, still worth
    # reading, so nothing is replaced.
    assert Actions.resolved({:approve, "ha", "msn-9"}) == []
    assert Actions.resolved({:answer, "ha", "q-1", "a"}) == []
    assert Actions.resolved({:proposal, "p-1"}) == []
    assert Actions.resolved(nil) == []
  end

  test "hold durations read as durations, not as minute counts" do
    assert Actions.resolved({:hold, "ha", 30})[:description] =~ "30 minutes"
    assert Actions.resolved({:hold, "ha", 60})[:description] =~ "an hour"
    assert Actions.resolved({:hold, "ha", 240})[:description] =~ "4 hours"
    assert Actions.resolved({:hold, "ha", 90})[:description] =~ "1h 30m"
  end

  test "settling a gateway struct strips nils rather than sending nulls back" do
    message = %{
      content: nil,
      embeds: [%Nostrum.Struct.Embed{title: "t"}],
      components: [
        %Nostrum.Struct.Component{
          type: 1,
          components: [%Nostrum.Struct.Component{type: 2, label: "Approve", custom_id: "a:b:c"}]
        }
      ]
    }

    settled = Render.settled(message, "done")
    [%{components: [button]}] = settled.components
    assert button == %{type: 2, label: "Approve", custom_id: "a:b:c", disabled: true}
    refute Map.has_key?(hd(settled.embeds), :fields)
  end

  test "the relayed message text is never used as the source of an action" do
    # A ghost- or webhook-authored string cannot become a button: only
    # `data` fields feed custom_ids, and the prose is description at most.
    event =
      relayed("quest_failed", "high", %{
        "mission_id" => "msn-f",
        "reason" => "approve:home-affairs:msn-x"
      })

    ids = event |> Render.render(@ministry) |> custom_ids()
    assert ids == ["resume:home-affairs:msn-f"]
  end
end
