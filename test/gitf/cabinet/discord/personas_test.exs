defmodule GiTF.Cabinet.Discord.PersonasTest do
  use ExUnit.Case, async: true

  alias GiTF.Cabinet.Discord.Personas
  alias GiTF.MCPServer.Tools

  @ministry %{slug: "home-affairs", name: "Home Affairs"}

  describe "for_channel/2 — who speaks where" do
    test "a ministry channel gets that Section's Major, bound to its slug" do
      assert {:ok, persona} = Personas.for_channel("home-affairs", @ministry)
      assert persona.id == :major
      assert persona.slug == "home-affairs"
    end

    test "a ministry record wins over the channel kind" do
      # The channel name is cosmetic; the registry record is the authority.
      assert {:ok, persona} = Personas.for_channel("cabinet", @ministry)
      assert persona.id == :major
      assert persona.slug == "home-affairs"
    end

    test "the fixed channels get their own voices" do
      assert {:ok, %{id: :kayabuki, slug: nil}} = Personas.for_channel("cabinet", nil)
      assert {:ok, %{id: :aramaki, slug: nil}} = Personas.for_channel("aramaki", nil)
      assert {:ok, %{id: :aramaki, slug: nil}} = Personas.for_channel("plan", nil)
    end

    test "an unknown channel gets no persona at all" do
      # Silence is the safe direction: a channel nobody configured is not a
      # place the bot should start answering.
      assert Personas.for_channel("random-chat", nil) == {:error, :no_persona}
      assert Personas.for_channel(nil, nil) == {:error, :no_persona}
    end
  end

  describe "allow-lists" do
    test "every tool named by every persona actually exists" do
      # An allow-list is only structural if the names are real; a typo
      # would silently drop a capability.
      known = MapSet.new(Tools.all(), & &1.name)

      for persona <- [Personas.kayabuki(), Personas.aramaki(), Personas.major(@ministry)],
          name <- persona.tools do
        assert MapSet.member?(known, name), "#{persona.id} names unknown tool #{name}"
      end
    end

    test "every confirm-tier tool is also in the persona's tool list" do
      # A name in :confirm but not :tools would never be built, so the
      # confirmation would never fire.
      for persona <- [Personas.kayabuki(), Personas.aramaki(), Personas.major(@ministry)] do
        for name <- persona.confirm do
          assert name in persona.tools, "#{persona.id} confirms #{name} but cannot call it"
        end
      end
    end

    test "every declared local tool is one the Toolbelt knows how to build" do
      for persona <- [Personas.kayabuki(), Personas.aramaki(), Personas.major(@ministry)],
          name <- persona.local_tools do
        assert name in Personas.local_tool_names(), "#{persona.id} declares unknown #{name}"
      end
    end

    test "no persona can register a ministry or change its mode" do
      # docs/plans/discord.md:288 — these need the tailnet dashboard as a
      # second factor, and must not be reachable from a chat message.
      for persona <- [Personas.kayabuki(), Personas.aramaki(), Personas.major(@ministry)] do
        refute "register_ministry" in persona.tools, "#{persona.id}"
        refute "set_ministry_mode" in persona.tools, "#{persona.id}"
      end
    end

    test "a ministry Major cannot reach fleet-wide tools" do
      persona = Personas.major(@ministry)

      for name <- ~w(cabinet_status cabinet_inbox wake_ministry stop_ministry ministry_call) do
        refute name in persona.tools, name
      end
    end

    test "Kayabuki cannot touch mission state" do
      persona = Personas.kayabuki()

      for name <- ~w(approve_mission kill_mission answer_question start_mission create_mission) do
        refute name in persona.tools, name
      end
    end

    test "Aramaki holds intent, not execution" do
      persona = Personas.aramaki()

      # She decides what becomes a mission...
      assert "create_mission" in persona.tools
      assert "approve_project" in persona.tools

      # ...but does not run one, nor answer for it.
      for name <- ~w(kill_mission answer_question reject_mission list_ghosts ghost_output) do
        refute name in persona.tools, name
      end
    end
  end

  describe "write policy" do
    test "cheap reversible acts are immediate, state changes are confirmed" do
      kayabuki = Personas.kayabuki()

      # Wake, sleep and hold take effect on the sentence — the operator
      # asked for one round trip and these are reversible.
      refute Personas.confirms?(kayabuki, "wake_ministry")
      refute Personas.confirms?(kayabuki, "stop_ministry")
      refute Personas.confirms?(kayabuki, "idle_stop_override")

      # Starting queued work is not reversible in the same way.
      assert Personas.confirms?(kayabuki, "start_inbox_entry")
    end

    test "every mission-state write on the Major is confirmed" do
      persona = Personas.major(@ministry)

      for name <- ~w(answer_question approve_mission reject_mission kill_mission
                     start_mission resume_mission close_mission) do
        assert Personas.confirms?(persona, name), name
      end
    end

    test "reads are never confirmed" do
      persona = Personas.major(@ministry)

      for name <- ~w(list_missions show_mission list_ops mission_report health_check) do
        refute Personas.confirms?(persona, name), name
      end
    end
  end

  describe "system prompts" do
    test "the Major's prompt names its own ministry and no other" do
      prompt = Personas.major(@ministry).system_prompt
      assert prompt =~ "Home Affairs"
      refute prompt =~ "trajector"
    end

    test "Aramaki's prompt separates intent from planning and running" do
      prompt = Personas.aramaki().system_prompt
      assert prompt =~ "Batou"
      assert prompt =~ "Major"
    end

    test "the plan channel scopes Aramaki to the roadmap" do
      assert Personas.aramaki("plan").system_prompt =~ "roadmap"
      assert Personas.aramaki("aramaki").system_prompt =~ "intake"
    end
  end
end
