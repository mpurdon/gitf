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
    assert hd(message.embeds).title == "Sleeping in ~9 min"
    assert hd(message.embeds).description =~ "1 mission(s) are holding"

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
    settled = event |> Render.render(@ministry) |> Render.settled("✓ approved by @matt · 21:04")

    assert Enum.all?(settled.components, fn row -> Enum.all?(row.components, & &1.disabled) end)
    assert hd(settled.embeds).footer.text == "✓ approved by @matt · 21:04"
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
