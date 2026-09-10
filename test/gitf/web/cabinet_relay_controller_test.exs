defmodule GiTF.Web.CabinetRelayControllerTest do
  @moduledoc """
  `POST /relay/:ministry` — a factory's alerts on their way to Discord.
  Same door policy as the GitHub ingress: the ministry's secret signs it,
  and anything else is 404.
  """
  use GiTF.StoreCase

  import Phoenix.ConnTest

  alias GiTF.Cabinet.Registry
  alias GiTF.Web.CabinetRelayController

  @secret "relay-test-secret-0123456789"
  @env "GITF_TEST_CABINET_RELAY_SECRET"

  setup do
    System.put_env(@env, @secret)
    on_exit(fn -> System.delete_env(@env) end)

    {:ok, m} =
      Registry.create(%{
        slug: "relayed-#{:erlang.unique_integer([:positive])}",
        name: "Relayed",
        url: nil,
        webhook_secret_env: @env
      })

    %{ministry: m}
  end

  defp deliver(slug, body, signature) do
    build_conn(:post, "/relay/#{slug}", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("x-hub-signature-256", signature)
    |> Plug.Conn.assign(:raw_body, body)
    |> Map.put(:body_params, Jason.decode!(body))
    |> CabinetRelayController.receive(%{"ministry" => slug})
  end

  defp envelope do
    GiTF.Plugin.Builtin.Channels.Discord.envelope("alert", :quest_failed, :high, "lost", %{
      mission_id: "msn-1",
      reason: "lost"
    })
    |> Jason.encode!()
  end

  test "a signed envelope is accepted; without a bot it is received, not posted", %{ministry: m} do
    body = envelope()
    conn = deliver(m.slug, body, GiTF.Web.Signature.sign(body, @secret))
    assert json_response(conn, 200) == %{"ok" => true, "posted" => false}
  end

  test "a bad signature, an unknown slug, and a bodiless post are all 404", %{ministry: m} do
    body = envelope()
    bad = deliver(m.slug, body, "sha256=" <> String.duplicate("0", 64))
    unknown = deliver("no-such-ministry", body, GiTF.Web.Signature.sign(body, @secret))
    empty = deliver(m.slug, "{}", GiTF.Web.Signature.sign("{}", @secret))

    for conn <- [bad, unknown, empty] do
      assert json_response(conn, 404) == %{"error" => "not found"}
    end
  end

  test "the relay route exists on the Cabinet router" do
    assert Phoenix.Router.route_info(GiTF.Web.CabinetRouter, "POST", "/relay/x", "cabinet.test") !=
             :error
  end
end
