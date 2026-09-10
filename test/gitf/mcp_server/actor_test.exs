defmodule GiTF.MCPServer.ActorTest do
  @moduledoc """
  `Handlers.call/3` runs a tool as a named person. The Cabinet relays a
  Discord tap as `discord:<user>`; the record on the factory must say so,
  and the factory's own "auto" namespace must stay off-limits.
  """
  use GiTF.StoreCase

  alias GiTF.MCPServer.Handlers
  alias GiTF.{Archive, Inquiry}

  setup do
    {:ok, m} =
      Archive.insert(:missions, %{
        name: "actor",
        goal: "pick",
        status: "active",
        sector_id: "no-such-sector",
        current_phase: "awaiting_input",
        input_return_phase: "design",
        artifacts: %{},
        ops: []
      })

    {:ok, inquiry, :asked} =
      Inquiry.ask(m.id, %{
        key: "layout",
        phase: "design",
        kind: :choice,
        prompt: "Which layout?",
        options: [%{id: "grid", label: "Grid"}, %{id: "list", label: "List"}]
      })

    %{inquiry: inquiry}
  end

  test "an answer over the MCP is attributed to the named actor", %{inquiry: inq} do
    assert {:ok, _} =
             Handlers.call(
               "answer_question",
               %{"id" => inq.id, "answer" => "list", "confirm" => true},
               actor: "discord:matt"
             )

    assert Inquiry.get(inq.id).answered_by == "discord:matt"
  end

  test "without an actor the surface names itself, as before", %{inquiry: inq} do
    assert {:ok, _} =
             Handlers.call("answer_question", %{
               "id" => inq.id,
               "answer" => "grid",
               "confirm" => true
             })

    assert Inquiry.get(inq.id).answered_by == "mcp_operator"
  end

  test "the auto namespace is refused — it means a machine timeout", %{inquiry: inq} do
    assert {:error, msg} =
             Handlers.call(
               "answer_question",
               %{"id" => inq.id, "answer" => "grid", "confirm" => true},
               actor: "auto-discord"
             )

    assert msg =~ "reserved"
    assert Map.get(Inquiry.get(inq.id), :answered_by) == nil
  end

  test "the actor does not leak into later calls on the same process", %{inquiry: inq} do
    Handlers.call("list_missions", %{}, actor: "discord:matt")
    Handlers.call("answer_question", %{"id" => inq.id, "answer" => "grid", "confirm" => true})
    assert Inquiry.get(inq.id).answered_by == "mcp_operator"
  end

  test "the RPC layer passes params.actor through", %{inquiry: inq} do
    GiTF.MCPServer.handle_rpc(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{
        "name" => "answer_question",
        "arguments" => %{"id" => inq.id, "answer" => "list", "confirm" => true},
        "actor" => "discord:matt"
      }
    })

    assert Inquiry.get(inq.id).answered_by == "discord:matt"
  end
end
