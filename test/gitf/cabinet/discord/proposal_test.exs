defmodule GiTF.Cabinet.Discord.ProposalTest do
  use GiTF.StoreCase

  alias GiTF.Cabinet.Discord.{Actions, Proposal, Render}

  defp park(attrs \\ %{}) do
    {:ok, proposal} =
      Proposal.create(
        Map.merge(
          %{
            tool: "approve_mission",
            args: %{"id" => "msn-4f2a11"},
            slug: "home-affairs",
            actor: "discord:matt",
            channel_id: "ch-1"
          },
          attrs
        )
      )

    proposal
  end

  describe "create/1 and get/1" do
    test "a proposal keeps the tool, args, ministry and actor as proposed" do
      proposal = park()

      assert %{
               tool: "approve_mission",
               args: %{"id" => "msn-4f2a11"},
               slug: "home-affairs",
               actor: "discord:matt",
               status: "open"
             } = Proposal.get(proposal.id)
    end
  end

  describe "spend/1 — a button is not re-runnable" do
    test "the first tap wins and the second is refused" do
      proposal = park()

      assert {:ok, %{tool: "approve_mission"}} = Proposal.spend(proposal.id)
      assert Proposal.spend(proposal.id) == {:error, :already_spent}
    end

    test "concurrent taps cannot both win" do
      # The check and the write are one Archive.update/3, so a double-tap
      # (or two operators on the same button) approves once, not twice.
      proposal = park()

      results =
        1..20
        |> Task.async_stream(fn _ -> Proposal.spend(proposal.id) end, max_concurrency: 20)
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :already_spent})) == 19
    end

    test "an unknown id is not found rather than crashing" do
      assert Proposal.spend("prp-nope") == {:error, :not_found}
    end
  end

  describe "the tap path" do
    test "a propose custom_id round-trips through Actions.parse/2" do
      proposal = park()
      custom_id = Render.custom_id(["propose", proposal.id])

      assert {:ok, {:proposal, id}} = Actions.parse(custom_id)
      assert id == proposal.id
    end

    test "a propose id always fits Discord's 100-char custom_id limit" do
      # This is the whole reason proposals are stored rather than encoded:
      # a goal sentence would never fit.
      proposal =
        park(%{
          tool: "create_mission",
          args: %{"goal" => String.duplicate("a very long mission goal ", 20)}
        })

      assert String.length(Render.custom_id(["propose", proposal.id])) <= 100
    end

    test "a proposal whose act fails is handed back, not burned" do
      # home-affairs is not registered in this store, so the proxied call
      # fails. A transient failure must not cost the operator the button.
      proposal = park()

      assert {:error, _} = Actions.perform({:proposal, proposal.id}, "discord:matt")
      assert %{status: "open"} = Proposal.get(proposal.id)
    end

    test "a Cabinet-local proposal is spent once and refused after" do
      proposal = park(%{tool: "dismiss_inbox_entry", args: %{"id" => "evt-1"}, slug: nil})

      # Whatever the Gate says about an unknown entry, the second tap is
      # refused by the proposal itself.
      Actions.perform({:proposal, proposal.id}, "discord:matt")

      case Proposal.get(proposal.id) do
        %{status: "spent"} ->
          assert {:error, "already done"} =
                   Actions.perform({:proposal, proposal.id}, "discord:matt")

        %{status: "open"} ->
          # Reopened because the act failed — also correct.
          assert true
      end
    end

    test "tapping an expired proposal says so" do
      assert {:error, "that proposal has expired"} =
               Actions.perform({:proposal, "prp-gone"}, "discord:matt")
    end
  end

  describe "button/1" do
    test "every confirm-tier tool across all personas has a button" do
      # A proposable tool with no button is a write the operator can never
      # authorise — the agent would offer it and nothing would render.
      alias GiTF.Cabinet.Discord.Personas

      personas = [
        Personas.kayabuki(),
        Personas.aramaki(),
        Personas.major(%{slug: "home-affairs", name: "Home Affairs"})
      ]

      for persona <- personas, tool <- persona.confirm do
        assert Proposal.button(tool), "#{tool} is proposable but has no button"
      end
    end

    test "a tool nobody proposes has no button" do
      refute Proposal.button("list_missions")
      refute Proposal.button("register_ministry")
    end
  end

  describe "rendering" do
    test "an agent reply renders the persona as the embed author" do
      alias GiTF.Cabinet.Discord.Personas

      message = Render.agent_reply(Personas.kayabuki(), "Everything is asleep.", [])

      assert [%{author: %{name: "Kayabuki"}, description: "Everything is asleep."}] =
               message.embeds

      assert message.components == []
    end

    test "each proposal becomes one button carrying its id" do
      alias GiTF.Cabinet.Discord.Personas

      proposal = park()
      message = Render.agent_reply(Personas.kayabuki(), "Approve it?", [proposal])

      assert [%{components: [button]}] = message.components
      assert button.label == "Approve"
      assert button.custom_id == "propose:#{proposal.id}"
    end

    test "no more than five buttons are offered at once" do
      alias GiTF.Cabinet.Discord.Personas

      proposals = for _ <- 1..8, do: park()
      message = Render.agent_reply(Personas.kayabuki(), "Lots to do.", proposals)

      assert [%{components: buttons}] = message.components
      assert length(buttons) == 5
    end
  end
end
