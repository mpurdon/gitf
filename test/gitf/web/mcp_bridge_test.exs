defmodule GiTF.Web.McpBridgeTest do
  use GiTF.StoreCase

  import Phoenix.ConnTest

  alias GiTF.Web.ApiController

  defp rpc_conn(message) do
    build_conn(:post, "/api/v1/mcp", message)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Map.put(:body_params, message)
  end

  defp call(message) do
    conn = rpc_conn(message)
    ApiController.mcp(conn, conn.body_params)
  end

  test "initialize returns the JSON-RPC envelope with server info" do
    conn = call(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["jsonrpc"] == "2.0"
    assert body["id"] == 1
    assert body["result"]["serverInfo"]["name"] == "gitf"
  end

  test "tools/list returns the tool catalog" do
    conn = call(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    tool_names = Enum.map(body["result"]["tools"], & &1["name"])
    assert "list_missions" in tool_names
  end

  test "tools/call answers from this daemon's store" do
    {:ok, mission} = GiTF.Missions.create(%{goal: "bridge test mission"})

    conn =
      call(%{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{"name" => "list_missions", "arguments" => %{}}
      })

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    [%{"text" => text}] = body["result"]["content"]
    assert text =~ mission.id
  end

  test "unknown method returns a JSON-RPC error, not an HTTP error" do
    conn = call(%{"jsonrpc" => "2.0", "id" => 4, "method" => "nope/nope"})

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == -32601
  end

  test "notifications get 204 with no body" do
    conn = call(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

    assert conn.status == 204
    assert conn.resp_body == ""
  end
end
