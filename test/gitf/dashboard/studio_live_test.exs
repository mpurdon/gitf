defmodule GiTF.Dashboard.StudioLiveTest do
  use ExUnit.Case, async: false

  import Mox
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias GiTF.Studio.Session

  @endpoint GiTF.Web.Endpoint

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    endpoint_alive? =
      case Process.whereis(GiTF.Web.Endpoint) do
        nil -> false
        pid -> Process.alive?(pid)
      end

    ets_ok? =
      try do
        GiTF.Web.Endpoint.config(:pubsub_server)
        true
      rescue
        ArgumentError -> false
      end

    if !(endpoint_alive? and ets_ok?) do
      GiTF.Test.StoreHelper.safe_stop(GiTF.Web.Endpoint)
      Process.sleep(50)
      current = Application.get_env(:gitf, GiTF.Web.Endpoint, [])
      Application.put_env(:gitf, GiTF.Web.Endpoint, Keyword.put(current, :server, false))
      {:ok, _} = GiTF.Web.Endpoint.start_link([])
    end

    Application.put_env(:gitf, :llm_client, GiTF.Runtime.LLMClient.Mock)
    on_exit(fn -> Application.delete_env(:gitf, :llm_client) end)

    :ok
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

  defp tool_response(name, args) do
    %ReqLLM.Response{
      id: "mock",
      model: "mock-model",
      usage: %{},
      context: ReqLLM.Context.new([]),
      message: %ReqLLM.Message{
        role: :assistant,
        content: [ReqLLM.Message.ContentPart.text("Proposing.")],
        tool_calls: [%{id: "tc-1", name: name, arguments: args}]
      }
    }
  end

  defp await_session_idle(id, tries \\ 50) do
    state = Session.get_state(id)

    cond do
      state.status == :idle -> state
      tries == 0 -> raise "session never went idle"
      true ->
        Process.sleep(20)
        await_session_idle(id, tries - 1)
    end
  end

  test "studio mounts, starts a session, and streams planner output into the transcript" do
    stub(GiTF.Runtime.LLMClient.Mock, :generate_text, fn _, _, _ ->
      {:ok, text_response("What are we building today?")}
    end)

    # Connected mount starts a session and live-redirects to its URL.
    {:error, {:live_redirect, %{to: "/dashboard/studio/" <> session_id}}} =
      live(build_conn(), "/dashboard/studio")

    await_session_idle(session_id)

    {:ok, view, _html} = live(build_conn(), "/dashboard/studio/#{session_id}")
    assert render(view) =~ "What are we building today?"

    # Sending a message re-engages the planner and lands in the transcript.
    view
    |> form("form[phx-submit=send]", %{"message" => %{"text" => "A review app"}})
    |> render_submit()

    await_session_idle(session_id)
    assert render(view) =~ "A review app"
  end

  test "proposal cards render translucent and confirming merges them into the brief board" do
    GiTF.Runtime.LLMClient.Mock
    |> expect(:generate_text, fn _, _, _ ->
      {:ok, tool_response("add_decision", %{"text" => "SQLite for storage"})}
    end)
    |> expect(:generate_text, fn _, _, _ -> {:ok, text_response("Carded.")} end)

    {:ok, session_id} = Session.start_session()
    await_session_idle(session_id)

    {:ok, view, html} = live(build_conn(), "/dashboard/studio/#{session_id}")
    assert html =~ "SQLite for storage"
    assert html =~ "Confirm"

    [proposal] = Session.get_state(session_id).proposals

    view
    |> element("button[phx-click=confirm_card][phx-value-id=#{proposal.id}]")
    |> render_click()

    # PubSub round-trip: the confirmed decision moves to the Decided lane.
    html = render(view)
    assert html =~ "SQLite for storage"
    refute html =~ "Confirm this"
    assert Session.get_state(session_id).brief.decisions == ["SQLite for storage"]
  end

  test "expired session redirects back to a fresh studio" do
    conn = build_conn()

    {:error, {:redirect, %{to: "/dashboard/studio"}}} =
      live(conn, "/dashboard/studio/std-deadbeef")
  end

end
