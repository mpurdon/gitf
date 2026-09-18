defmodule GiTF.Cabinet.Discord.ToolbeltTest do
  use GiTF.StoreCase

  alias GiTF.Cabinet.Discord.{Personas, Toolbelt}

  @ministry %{slug: "home-affairs", name: "Home Affairs"}
  @actor "discord:matt"

  defp build(persona, opts \\ []) do
    Toolbelt.build(persona, Keyword.merge([actor: @actor], opts))
  end

  defp names(tools), do: Enum.map(tools, & &1.name) |> Enum.sort()

  defp tool(tools, name), do: Enum.find(tools, &(&1.name == name))

  describe "build/2" do
    test "builds exactly the persona's declared tools, no more" do
      persona = Personas.kayabuki()
      tools = build(persona)

      assert names(tools) == Enum.sort(Enum.uniq(Personas.tool_names(persona)))
    end

    test "only Kayabuki can address another ministry" do
      # One hop, structurally: a Major with ask_ministry could chain from
      # Section to Section.
      assert tool(build(Personas.kayabuki()), "ask_ministry")
      refute tool(build(Personas.major(@ministry)), "ask_ministry")
      refute tool(build(Personas.aramaki()), "ask_ministry")
    end

    test "a tool outside the allow-list is not built at all" do
      # The guarantee is structural: absent from the list means absent from
      # the loop, so no conversation can reach it.
      tools = build(Personas.major(@ministry))

      refute tool(tools, "register_ministry")
      refute tool(tools, "wake_ministry")
      refute tool(tools, "cabinet_status")
    end

    test "an allow-list naming a tool that no longer exists is skipped, not fatal" do
      persona = %{
        Personas.kayabuki()
        | tools: ["health_check", "tool_that_never_existed"],
          local_tools: []
      }

      tools = build(persona)
      assert names(tools) == ["health_check"]
    end

    test "tools with parameters carry their schema; parameterless ones do not" do
      tools = build(Personas.major(@ministry))

      # list_missions takes filters...
      assert tool(tools, "list_missions").parameter_schema

      # ...factory_status takes nothing.
      assert tool(tools, "factory_status").parameter_schema in [nil, []]
    end
  end

  describe "the ministry is bound, not an argument" do
    test "no ministry tool exposes a slug parameter the model could set" do
      # This is the isolation guarantee. If `slug` were a parameter, the
      # Major in #home-affairs could name any Section and read it.
      for t <- build(Personas.major(@ministry)) do
        schema = t.parameter_schema

        if is_map(schema) do
          props = Map.get(schema, :properties, %{})

          for key <- [:slug, "slug", :ministry, "ministry"] do
            refute Map.has_key?(props, key), "#{t.name} exposes #{key}"
          end
        end
      end
    end

    test "a ministry tool routes to its own slug even when args name another" do
      # Belt and braces: even if the model invents a slug argument, the
      # closure's slug is the one used. Neither ministry is registered in
      # this store, so the call fails — but the failure must be about
      # home-affairs, never about trajector.
      tools = build(Personas.major(@ministry))
      t = tool(tools, "list_missions")

      {:ok, text} = t.callback.(%{"slug" => "trajector", "all" => true})

      assert text =~ "Tool failed"
      refute text =~ "trajector"
    end
  end

  describe "confirm tier" do
    test "a confirmed tool proposes instead of performing" do
      tools = build(Personas.major(@ministry), proposals_to: self())
      t = tool(tools, "approve_mission")

      {:ok, text} = t.callback.(%{"id" => "msn-4f2a11"})

      assert_received {:tool_proposal, "approve_mission", args}
      assert args["id"] == "msn-4f2a11"
      assert text =~ "Proposed"
      assert text =~ "do not report it as done"
    end

    test "an immediate tool performs and proposes nothing" do
      tools = build(Personas.kayabuki(), proposals_to: self())
      t = tool(tools, "health_check")

      {:ok, _text} = t.callback.(%{})

      refute_received {:tool_proposal, _, _}
    end

    test "proposals reach the collector from another process" do
      # AgentLoop runs tool callbacks inside Task.async (agent_loop.ex:243),
      # so a proposal must survive the process hop to the agent.
      tools = build(Personas.major(@ministry), proposals_to: self())
      t = tool(tools, "kill_mission")

      Task.async(fn -> t.callback.(%{"id" => "msn-1"}) end) |> Task.await()

      assert_received {:tool_proposal, "kill_mission", %{"id" => "msn-1"}}
    end
  end

  describe "failures are information, not aborts" do
    test "a tool error comes back as :ok text so the loop can react" do
      # ReqLLM aborts on {:error, _}; a factory error is something the
      # model should read and explain, not a crash.
      tools = build(Personas.major(@ministry))
      t = tool(tools, "show_mission")

      assert {:ok, text} = t.callback.(%{"id" => "msn-does-not-exist"})
      assert is_binary(text)
    end
  end

  describe "argument handling" do
    test "atom keys are stringified for the MCP handlers" do
      tools = build(Personas.kayabuki(), proposals_to: self())
      t = tool(tools, "start_inbox_entry")

      {:ok, _} = t.callback.(%{id: "evt-1"})

      assert_received {:tool_proposal, "start_inbox_entry", args}
      assert args["id"] == "evt-1"
    end

    test "a non-map argument does not crash the callback" do
      tools = build(Personas.kayabuki())
      t = tool(tools, "health_check")

      assert {:ok, _} = t.callback.(nil)
    end
  end
end
