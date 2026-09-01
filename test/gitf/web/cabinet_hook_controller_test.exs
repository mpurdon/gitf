defmodule GiTF.Web.CabinetHookControllerTest do
  # The Cabinet's public ingress. Shipped once with a controller that sent
  # the JSON response and then returned the ORIGINAL conn (Plug raised
  # NotSentError after the body had gone out) — GitHub logged a 500 for a
  # delivery the Gate had already handled. `json_response/2` checks the conn
  # state, so these assertions catch exactly that.
  use GiTF.StoreCase

  import Phoenix.ConnTest

  alias GiTF.Cabinet.Registry
  alias GiTF.Web.CabinetHookController

  @secret "cabinet-test-secret-0123456789"
  @env "GITF_TEST_CABINET_HOOK_SECRET"

  setup do
    System.put_env(@env, @secret)
    on_exit(fn -> System.delete_env(@env) end)

    {:ok, m} =
      Registry.create(%{
        slug: "hooked-#{:erlang.unique_integer([:positive])}",
        name: "Hooked",
        url: nil,
        webhook_secret_env: @env
      })

    %{ministry: m}
  end

  defp deliver(slug, event, body, signature) do
    build_conn(:post, "/hooks/#{slug}", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("x-github-event", event)
    |> Plug.Conn.put_req_header("x-github-delivery", "d-1")
    |> Plug.Conn.put_req_header("x-hub-signature-256", signature)
    |> Plug.Conn.assign(:raw_body, body)
    |> Map.put(:body_params, Jason.decode!(body))
    |> CabinetHookController.receive(%{"ministry" => slug})
  end

  defp sign(body),
    do: "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, @secret, body), case: :lower)

  test "a signed ping is answered 200 with the gate's outcome", %{ministry: m} do
    body = Jason.encode!(%{zen: "Keep it logically awesome.", hook_id: 1})
    conn = deliver(m.slug, "ping", body, sign(body))

    assert json_response(conn, 200) == %{"ok" => true, "outcome" => "drop", "event" => "ping"}
  end

  test "a signed feature issue queues and still answers 200", %{ministry: m} do
    body =
      Jason.encode!(%{
        action: "opened",
        issue: %{number: 12, title: "Add dark mode", labels: [%{name: "enhancement"}]}
      })

    conn = deliver(m.slug, "issues", body, sign(body))
    assert %{"ok" => true, "outcome" => "queue"} = json_response(conn, 200)
  end

  test "a bad signature is 404, indistinguishable from an unknown slug", %{ministry: m} do
    body = Jason.encode!(%{zen: "x"})
    bad = deliver(m.slug, "ping", body, "sha256=" <> String.duplicate("0", 64))
    unknown = deliver("no-such-ministry", "ping", body, sign(body))

    assert json_response(bad, 404) == %{"error" => "not found"}
    assert json_response(unknown, 404) == %{"error" => "not found"}
  end
end
