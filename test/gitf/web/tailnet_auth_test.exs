defmodule GiTF.Web.TailnetAuthTest do
  use ExUnit.Case, async: false

  alias GiTF.Web.TailnetAuth

  defp set_auth(mode, admins \\ nil) do
    Application.put_env(:gitf, :tailnet_auth, mode)
    if admins, do: Application.put_env(:gitf, :tailnet_admins, admins)

    on_exit(fn ->
      Application.delete_env(:gitf, :tailnet_auth)
      Application.delete_env(:gitf, :tailnet_admins)
    end)
  end

  defp call(conn), do: TailnetAuth.call(conn, [])

  defp loopback_conn do
    %{Plug.Test.conn(:get, "/dashboard") | remote_ip: {127, 0, 0, 1}}
    |> Plug.Test.init_test_session(%{})
  end

  test "local caller passes and gets identity in session" do
    set_auth(:required, ["mp@example.com"])
    conn = call(loopback_conn())

    refute conn.halted
    assert conn.assigns.tailnet_identity.kind == :local
    assert Plug.Conn.get_session(conn, :tailnet_login) == "local"
  end

  test "unidentifiable peer is 403ed in required mode" do
    set_auth(:required)

    conn =
      %{Plug.Test.conn(:get, "/dashboard") | remote_ip: {192, 168, 1, 50}}
      |> Plug.Test.init_test_session(%{})
      |> call()

    assert conn.halted
    assert conn.status == 403
  end

  test "unidentifiable peer passes in off mode with nil identity" do
    set_auth(:off)

    conn =
      %{Plug.Test.conn(:get, "/dashboard") | remote_ip: {192, 168, 1, 50}}
      |> Plug.Test.init_test_session(%{})
      |> call()

    refute conn.halted
    assert conn.assigns.tailnet_identity == nil
  end

  describe "on_mount/4" do
    test "continues with identity from session" do
      set_auth(:required, ["mp@example.com"])
      socket = %Phoenix.LiveView.Socket{}

      assert {:cont, socket} =
               TailnetAuth.on_mount(
                 :default,
                 %{},
                 %{"tailnet_login" => "mp@example.com", "tailnet_kind" => "tailnet"},
                 socket
               )

      assert socket.assigns.tailnet_identity.login == "mp@example.com"
    end

    test "halts a socket with no session identity in required mode" do
      set_auth(:required)
      socket = %Phoenix.LiveView.Socket{}

      assert {:halt, _} = TailnetAuth.on_mount(:default, %{}, %{}, socket)
    end

    test "halts a non-admin identity when an admin list is set" do
      set_auth(:required, ["mp@example.com"])
      socket = %Phoenix.LiveView.Socket{}

      assert {:halt, _} =
               TailnetAuth.on_mount(
                 :default,
                 %{},
                 %{"tailnet_login" => "intruder@example.com", "tailnet_kind" => "tailnet"},
                 socket
               )
    end
  end

  describe "actor/1" do
    test "extracts the login" do
      assert TailnetAuth.actor(%{tailnet_identity: %{login: "mp@example.com"}}) ==
               "mp@example.com"
    end

    test "falls back when identity is absent" do
      assert TailnetAuth.actor(%{}) == "unidentified"
      assert TailnetAuth.actor(%{tailnet_identity: nil}) == "unidentified"
    end
  end
end
