defmodule GiTF.Cabinet.Discord.AgentTest do
  use GiTF.StoreCase

  alias GiTF.Cabinet.Discord.{Agent, Conversation, Personas}
  alias GiTF.Cabinet.Registry
  alias GiTF.Test.ScriptedLLMClient
  alias ReqLLM.{Context, Message, Response}
  alias ReqLLM.Message.ContentPart

  @actor "discord:matt"

  setup do
    previous = Application.get_env(:gitf, :llm_client)
    Application.put_env(:gitf, :llm_client, ScriptedLLMClient)
    on_exit(fn -> Application.put_env(:gitf, :llm_client, previous) end)

    {:ok, home} =
      Registry.create(%{slug: "home-affairs", name: "Home Affairs", url: "https://ha.example"})

    {:ok, _} = Registry.create(%{slug: "trajector", name: "Trajector", url: "https://tj.example"})

    %{home: home}
  end

  defp script(rules), do: {:ok, _} = ScriptedLLMClient.start_scenario(rules)

  defp say(text), do: %{match: text, response: ScriptedLLMClient.ok_text("ack")}

  defp reply(match, text), do: %{match: match, response: ScriptedLLMClient.ok_text(text)}

  # A response that asks for one tool call, shaped the way AgentLoop reads
  # it: tool_calls on the message, and a real context to append results to.
  defp tool_call(match, name, args) do
    response = %Response{
      id: "scripted-#{:erlang.unique_integer([:positive])}",
      model: "sim:mock",
      context: Context.new([%Message{role: :user, content: [ContentPart.text("go")]}]),
      message: %Message{
        role: :assistant,
        content: [],
        tool_calls: [%{id: "call-1", name: name, arguments: args}]
      },
      object: nil,
      stream?: false,
      stream: nil,
      usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15},
      finish_reason: :tool_calls,
      provider_meta: %{},
      error: nil
    }

    %{match: match, response: {:ok, response}}
  end

  describe "answer/5 — who answers" do
    test "a ministry channel answers as that Section's Major", %{home: home} do
      script([reply("in progress", "Two missions running.")])

      assert {:ok, result} =
               Agent.answer("ch-1", "home-affairs", home, "what's in progress", @actor)

      assert result.persona.id == :major
      assert result.persona.slug == "home-affairs"
      assert result.reply == "Two missions running."
    end

    test "the cabinet channel answers as Kayabuki" do
      script([reply("awake", "Everything is asleep.")])

      assert {:ok, result} = Agent.answer("ch-2", "cabinet", nil, "what's awake", @actor)
      assert result.persona.id == :kayabuki
    end

    test "a channel no persona owns stays silent" do
      assert Agent.answer("ch-x", "off-topic", nil, "hello", @actor) == {:error, :no_persona}
    end
  end

  describe "conversation memory" do
    test "both sides of the exchange are remembered" do
      script([reply("first question", "first answer")])

      {:ok, _} = Agent.answer("ch-3", "cabinet", nil, "first question", @actor)

      turns = Conversation.load("ch-3")

      assert [%{role: :operator, text: "first question"}, %{role: :persona, text: "first answer"}] =
               turns
    end

    test "prior turns are injected into the next prompt" do
      script([
        reply("first question", "the sky is blue"),
        reply("the sky is blue", "still blue")
      ])

      {:ok, _} = Agent.answer("ch-4", "cabinet", nil, "first question", @actor)
      {:ok, second} = Agent.answer("ch-4", "cabinet", nil, "and now?", @actor)

      # The second rule only matches if the earlier answer was in the prompt.
      assert second.reply == "still blue"
    end

    test "a channel's history never leaks into another channel", %{home: home} do
      script([
        reply("secret cabinet business", "noted"),
        reply("what's in progress", "Two missions.")
      ])

      {:ok, _} = Agent.answer("cab", "cabinet", nil, "secret cabinet business", @actor)
      {:ok, _} = Agent.answer("min", "home-affairs", home, "what's in progress", @actor)

      # Isolation boundary 1. If the cabinet turn had been injected into the
      # ministry prompt, the first rule would have matched and been consumed.
      assert Conversation.load("min") |> Enum.map(& &1.text) == [
               "what's in progress",
               "Two missions."
             ]

      assert ScriptedLLMClient.unmatched_count() == 0
    end
  end

  describe "state snapshot is scoped to the persona" do
    test "Kayabuki sees the fleet" do
      script([reply("trajector", "Both are asleep.")])

      # She is the one persona entitled to the whole fleet; the rule only
      # matches because the snapshot listed it.
      assert {:ok, _} = Agent.answer("ch-5", "cabinet", nil, "status?", @actor)
      assert ScriptedLLMClient.unmatched_count() == 0
    end

    test "a ministry Major's prompt names only its own ministry", %{home: home} do
      # Isolation boundary 3: no rule may match on the other ministry, so a
      # snapshot that leaked the fleet would leave this rule unconsumed.
      script([
        %{match: "trajector", response: ScriptedLLMClient.ok_text("LEAKED")},
        reply("Home Affairs", "Nothing running.")
      ])

      assert {:ok, result} = Agent.answer("ch-6", "home-affairs", home, "status?", @actor)
      assert result.reply == "Nothing running."
    end
  end

  describe "proposals" do
    test "a confirm-tier tool call comes back as a proposal, not a write", %{home: home} do
      script([
        tool_call("approve it", "approve_mission", %{"id" => "msn-4f2a11"}),
        # Matching the tool result proves it was fed back into the next turn.
        reply("Proposed to the operator", "I've put an approval up for you.")
      ])

      assert {:ok, result} = Agent.answer("ch-7", "home-affairs", home, "approve it", @actor)

      assert [%{tool: "approve_mission", args: %{"id" => "msn-4f2a11"}}] = result.proposals
      assert result.reply == "I've put an approval up for you."
    end

    test "a turn with no tool calls proposes nothing" do
      script([reply("hello", "Hello.")])

      assert {:ok, result} = Agent.answer("ch-8", "cabinet", nil, "hello", @actor)
      assert result.proposals == []
    end

    test "proposals from a previous turn do not leak into the next", %{home: home} do
      script([
        tool_call("approve it", "approve_mission", %{"id" => "msn-1"}),
        reply("Proposed to the operator", "proposed"),
        reply("thanks", "you're welcome")
      ])

      {:ok, first} = Agent.answer("ch-9", "home-affairs", home, "approve it", @actor)
      assert length(first.proposals) == 1

      {:ok, second} = Agent.answer("ch-9", "home-affairs", home, "thanks", @actor)
      assert second.proposals == []
    end
  end

  describe "cross-ministry: Kayabuki asks, the Major answers" do
    test "the question crosses and the answer comes back", %{home: home} do
      Registry.update(home.id, &Map.put(&1, :discord_channel_id, 999))

      script([
        tool_call("what is home affairs doing", "ask_ministry", %{
          "ministry" => "home affairs",
          "question" => "what is in progress?"
        }),
        # The Major's own turn, in its own channel.
        reply("what is in progress?", "Two missions: msn-4f2a11 and msn-9c31bd."),
        # Back in Kayabuki's turn, with the Major's answer as the tool result.
        reply("home-affairs says", "home-affairs has two missions running.")
      ])

      assert {:ok, result} =
               Agent.answer("cab", "cabinet", nil, "what is home affairs doing", @actor)

      assert result.persona.id == :kayabuki
      assert result.reply =~ "two missions"

      assert [exchange] = result.cross_posts
      assert exchange.slug == "home-affairs"
      assert exchange.channel_id == 999
      assert exchange.question == "what is in progress?"
      assert exchange.reply =~ "msn-4f2a11"
      assert exchange.persona.id == :major
    end

    test "prose names the ministry; the resolver does the rest", %{home: home} do
      Registry.update(home.id, &Map.put(&1, :discord_channel_id, 999))

      script([
        tool_call("ask them", "ask_ministry", %{
          "ministry" => "Home Affairs",
          "question" => "status?"
        }),
        reply("status?", "Idle."),
        reply("home-affairs says", "They're idle.")
      ])

      assert {:ok, result} = Agent.answer("cab", "cabinet", nil, "ask them", @actor)
      assert [%{slug: "home-affairs"}] = result.cross_posts
    end

    test "an unknown ministry is reported, not guessed at" do
      script([
        tool_call("ask finance", "ask_ministry", %{
          "ministry" => "finance",
          "question" => "status?"
        }),
        reply("There is no ministry matching", "There's no finance ministry.")
      ])

      assert {:ok, result} = Agent.answer("cab", "cabinet", nil, "ask finance", @actor)
      assert result.cross_posts == []
    end

    test "a Major cannot ask another ministry", %{home: home} do
      # One hop only: the Major's toolbelt has no ask_ministry at all, so
      # a Section cannot chain to another Section.
      script([reply("what about trajector", "I only speak for Home Affairs.")])

      assert {:ok, result} =
               Agent.answer("min", "home-affairs", home, "what about trajector", @actor)

      assert result.cross_posts == []
    end
  end

  describe "grounding" do
    test "an id the persona never looked up is flagged in the reply", %{home: home} do
      # No tool call happened, so nothing is grounded — the mission id is
      # pure invention, and a read has no confirmation step to catch it.
      script([reply("what's running", "msn-deadbe is in implementation.")])

      assert {:ok, result} = Agent.answer("ch-g1", "home-affairs", home, "what's running", @actor)

      assert result.grounding == {:ungrounded, ["msn-deadbe"]}
      assert result.reply =~ "unverified"
    end

    test "ids that came back from a tool are grounded", %{home: home} do
      script([
        tool_call("what's running", "list_missions", %{}),
        # The tool result is an error (no such ministry in this store), but
        # whatever ids a result DOES carry become fair game. Here the reply
        # cites none, so it is grounded.
        reply("Tool failed", "Nothing I can see right now.")
      ])

      assert {:ok, result} = Agent.answer("ch-g2", "home-affairs", home, "what's running", @actor)
      assert result.grounding == :ok
      refute result.reply =~ "unverified"
    end

    test "a reply with no ids is never flagged" do
      script([reply("what's awake", "Everything is asleep.")])

      assert {:ok, result} = Agent.answer("ch-g3", "cabinet", nil, "what's awake", @actor)
      assert result.grounding == :ok
    end
  end

  describe "failure" do
    test "an LLM failure returns an error and discards any proposals", %{home: home} do
      script([%{match: "approve it", response: {:error, :provider_exploded}}])

      assert {:error, _} = Agent.answer("ch-10", "home-affairs", home, "approve it", @actor)

      # Nothing recorded: a half-finished turn should not look like a
      # conversation the persona remembers having.
      assert Conversation.load("ch-10") == []
    end

    test "an empty answer does not produce an empty message" do
      script([%{match: "hello", response: ScriptedLLMClient.empty_response()}])

      case Agent.answer("ch-11", "cabinet", nil, "hello", @actor) do
        {:ok, result} -> refute String.trim(result.reply) == ""
        {:error, _} -> :ok
      end
    end
  end
end
