defmodule GiTF.Studio.SessionTest do
  use ExUnit.Case, async: false

  import Mox

  alias GiTF.Studio.Session

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    tmp = Path.join(System.tmp_dir!(), "gitf_studio_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Archive.start_link(data_dir: tmp)

    Application.put_env(:gitf, :llm_client, GiTF.Runtime.LLMClient.Mock)

    on_exit(fn ->
      Application.delete_env(:gitf, :llm_client)
      File.rm_rf!(tmp)
    end)

    :ok
  end

  defp tool_response(name, args, id \\ "tc-1") do
    %ReqLLM.Response{
      id: "mock",
      model: "mock-model",
      usage: %{},
      context: ReqLLM.Context.new([]),
      message: %ReqLLM.Message{
        role: :assistant,
        content: [ReqLLM.Message.ContentPart.text("On it.")],
        tool_calls: [%{id: id, name: name, arguments: args}]
      }
    }
  end

  defp text_response(text) do
    %ReqLLM.Response{
      id: "mock",
      model: "mock-model",
      usage: %{},
      context: ReqLLM.Context.new([]),
      message: %ReqLLM.Message{
        role: :assistant,
        content: [ReqLLM.Message.ContentPart.text(text)]
      }
    }
  end

  defp await(fun, tries \\ 50) do
    case fun.() do
      nil when tries > 0 ->
        Process.sleep(20)
        await(fun, tries - 1)

      nil ->
        flunk("condition not reached")

      result ->
        result
    end
  end

  defp await_idle(id) do
    await(fn ->
      state = Session.get_state(id)
      if state.status == :idle, do: state
    end)
  end

  test "tool calls become proposals; confirmation merges them into the plan" do
    # Turn 1 (init): planner proposes a decision, then yields.
    GiTF.Runtime.LLMClient.Mock
    |> expect(:generate_text, fn _model, _ctx, _opts ->
      {:ok, tool_response("add_decision", %{"text" => "Use Phoenix LiveView"})}
    end)
    |> expect(:generate_text, fn _model, _ctx, _opts ->
      {:ok, text_response("Recorded. What else?")}
    end)

    {:ok, id} = Session.start_session()
    state = await(fn ->
      s = Session.get_state(id)
      if s.status == :idle and s.proposals != [], do: s
    end)

    assert [%{tool: "add_decision", id: prp_id}] = state.proposals
    assert state.brief.decisions == []

    Session.confirm_proposal(id, prp_id)
    state = await(fn ->
      s = Session.get_state(id)
      if s.proposals == [], do: s
    end)

    assert state.brief.decisions == ["Use Phoenix LiveView"]

    # Turn 2: the confirmation outcome is folded into the next user turn.
    GiTF.Runtime.LLMClient.Mock
    |> expect(:generate_text, fn _model, ctx, _opts ->
      user_texts =
        ctx
        |> Enum.filter(&(&1.role == :user))
        |> Enum.flat_map(fn m ->
          case m.content do
            parts when is_list(parts) -> Enum.map(parts, &(&1.text || ""))
            text when is_binary(text) -> [text]
            _ -> []
          end
        end)

      assert Enum.any?(user_texts, &String.contains?(&1, "Confirmed: add_decision"))
      {:ok, text_response("Noted.")}
    end)

    Session.user_message(id, "Let's talk data model")
    state = await_idle(id)

    assert Enum.any?(state.transcript, &(&1.role == :assistant and &1.text == "Noted."))
  end

  test "dismissed proposals do not touch the plan" do
    GiTF.Runtime.LLMClient.Mock
    |> expect(:generate_text, fn _, _, _ ->
      {:ok, tool_response("set_parti", %{"text" => "Everything is a thread"})}
    end)
    |> expect(:generate_text, fn _, _, _ -> {:ok, text_response("ok")} end)

    {:ok, id} = Session.start_session()

    state = await(fn ->
      s = Session.get_state(id)
      if s.status == :idle and s.proposals != [], do: s
    end)

    [%{id: prp_id}] = state.proposals
    Session.dismiss_proposal(id, prp_id)

    state = await(fn ->
      s = Session.get_state(id)
      if s.proposals == [], do: s
    end)

    assert state.brief.parti == nil
  end

  test "approve creates and activates a project from confirmed roadmap items" do
    {:ok, sector} = GiTF.Archive.insert(:sectors, %{name: "target", path: "/tmp/x"})

    GiTF.Runtime.LLMClient.Mock
    |> expect(:generate_text, fn _, _, _ ->
      {:ok,
       tool_response("upsert_roadmap_item", %{
         "id" => "scaffold",
         "title" => "Scaffold",
         "goal" => "Set it up. Verify: mix test"
       })}
    end)
    |> expect(:generate_text, fn _, _, _ -> {:ok, text_response("Roadmap started.")} end)

    {:ok, id} = Session.start_session()

    state = await(fn ->
      s = Session.get_state(id)
      if s.status == :idle and s.proposals != [], do: s
    end)

    [%{id: prp_id}] = state.proposals
    Session.confirm_proposal(id, prp_id)
    await(fn -> if Session.get_state(id).roadmap != [], do: true end)

    assert {:ok, project} = Session.approve(id, {:existing, sector.id})
    assert project.status == "active"
    assert project.source == "studio"
    assert [%{id: "scaffold", title: "Scaffold"}] = project.roadmap
    assert Session.get_state(id).project_id == project.id
  end

  test "phase advancement is a gate: only a confirmed card moves the phase" do
    GiTF.Runtime.LLMClient.Mock
    |> expect(:generate_text, fn _, _, _ ->
      {:ok, tool_response("set_phase", %{"phase" => "concept"})}
    end)
    |> expect(:generate_text, fn _, _, _ -> {:ok, text_response("gate proposed")} end)

    {:ok, id} = Session.start_session()

    state = await(fn ->
      s = Session.get_state(id)
      if s.status == :idle and s.proposals != [], do: s
    end)

    # Proposal exists but the phase has NOT moved yet.
    assert state.phase == "brief"
    [%{id: prp_id, tool: "set_phase"}] = state.proposals

    Session.confirm_proposal(id, prp_id)
    state = await(fn -> (s = Session.get_state(id)) && if s.proposals == [], do: s end)
    assert state.phase == "concept"
  end

  test "choose_scheme records the direction as a decision and clears the card" do
    schemes_args = %{
      "axis" => "data model",
      "schemes" => [
        %{"name" => "Threads", "thesis" => "Everything is a thread", "sacrifice" => "folders"},
        %{"name" => "Pile", "thesis" => "Search, never file", "sacrifice" => "browsing"}
      ]
    }

    GiTF.Runtime.LLMClient.Mock
    |> expect(:generate_text, fn _, _, _ -> {:ok, tool_response("propose_schemes", schemes_args)} end)
    |> expect(:generate_text, fn _, _, _ -> {:ok, text_response("pick one")} end)

    {:ok, id} = Session.start_session()

    state = await(fn ->
      s = Session.get_state(id)
      if s.status == :idle and s.proposals != [], do: s
    end)

    [%{id: prp_id}] = state.proposals
    Session.choose_scheme(id, prp_id, "Pile")

    state = await(fn -> (s = Session.get_state(id)) && if s.proposals == [], do: s end)
    assert ["data model: chose \"Pile\" — Search, never file"] = state.brief.decisions
  end

  test "confirmed storyboards are kept on the session" do
    board_args = %{
      "title" => "First review",
      "panels" => [
        %{"caption" => "Paste a URL", "description" => "landing page"},
        %{"caption" => "See the digest", "description" => "summary view"}
      ]
    }

    GiTF.Runtime.LLMClient.Mock
    |> expect(:generate_text, fn _, _, _ -> {:ok, tool_response("propose_storyboard", board_args)} end)
    |> expect(:generate_text, fn _, _, _ -> {:ok, text_response("boarded")} end)

    {:ok, id} = Session.start_session()

    state = await(fn ->
      s = Session.get_state(id)
      if s.status == :idle and s.proposals != [], do: s
    end)

    [%{id: prp_id}] = state.proposals
    Session.confirm_proposal(id, prp_id)

    state = await(fn -> (s = Session.get_state(id)) && if s.storyboards != [], do: s end)
    assert [%{title: "First review", panels: [_, _]}] = state.storyboards
  end

  test "broadcasts state updates on the session topic" do
    stub(GiTF.Runtime.LLMClient.Mock, :generate_text, fn _, _, _ ->
      {:ok, text_response("Hello!")}
    end)

    {:ok, id} = Session.start_session()
    Phoenix.PubSub.subscribe(GiTF.PubSub, Session.topic(id))
    await_idle(id)

    Session.user_message(id, "hi")
    # user message itself triggers a broadcast (status → thinking)
    assert_receive {:studio_update, %{id: ^id}}, 2_000
  end
end
