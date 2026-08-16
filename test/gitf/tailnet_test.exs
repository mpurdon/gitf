defmodule GiTF.TailnetTest do
  use ExUnit.Case, async: false

  alias GiTF.Tailnet

  # Distinct IPs per test so the persistent_term whois cache can't leak
  # results across cases.
  defp uniq_tailnet_ip do
    {100, 64 + :rand.uniform(63), :rand.uniform(254), :rand.uniform(254)}
  end

  defp put_whois(fun) do
    Application.put_env(:gitf, :tailnet_whois_fun, fun)
    on_exit(fn -> Application.delete_env(:gitf, :tailnet_whois_fun) end)
  end

  defp set_auth(mode, admins \\ nil) do
    Application.put_env(:gitf, :tailnet_auth, mode)
    if admins, do: Application.put_env(:gitf, :tailnet_admins, admins)

    on_exit(fn ->
      Application.delete_env(:gitf, :tailnet_auth)
      Application.delete_env(:gitf, :tailnet_admins)
    end)
  end

  describe "identity/1 with IP tuples" do
    test "loopback is local" do
      assert %{login: "local", kind: :local} = Tailnet.identity({127, 0, 0, 1})
      assert %{login: "local", kind: :local} = Tailnet.identity({0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "tailnet IP resolves through whois" do
      ip = uniq_tailnet_ip()

      put_whois(fn _ip ->
        {:ok,
         %{
           "UserProfile" => %{"LoginName" => "mp@example.com"},
           "Node" => %{"ComputedName" => "mbp"}
         }}
      end)

      assert %{login: "mp@example.com", kind: :tailnet, node: "mbp"} = Tailnet.identity(ip)
    end

    test "tagged device falls back to first tag" do
      ip = uniq_tailnet_ip()

      put_whois(fn _ip ->
        {:ok, %{"Node" => %{"Tags" => ["tag:ci"], "ComputedName" => "runner"}}}
      end)

      assert %{login: "tag:ci", kind: :tailnet} = Tailnet.identity(ip)
    end

    test "non-tailnet, non-loopback IP has no identity" do
      assert Tailnet.identity({192, 168, 1, 10}) == nil
      assert Tailnet.identity({8, 8, 8, 8}) == nil
    end

    test "whois failure yields nil, and nil is cached without crashing" do
      ip = uniq_tailnet_ip()
      put_whois(fn _ip -> :error end)

      assert Tailnet.identity(ip) == nil
      # Second call served from cache — still nil, no crash.
      assert Tailnet.identity(ip) == nil
    end

    test "whois results are cached per IP" do
      ip = uniq_tailnet_ip()
      counter = :counters.new(1, [])

      put_whois(fn _ip ->
        :counters.add(counter, 1, 1)
        {:ok, %{"UserProfile" => %{"LoginName" => "cached@example.com"}}}
      end)

      assert %{login: "cached@example.com"} = Tailnet.identity(ip)
      assert %{login: "cached@example.com"} = Tailnet.identity(ip)
      assert :counters.get(counter, 1) == 1
    end
  end

  describe "identity/1 with conns" do
    test "bare loopback conn is local" do
      conn = %{Plug.Test.conn(:get, "/") | remote_ip: {127, 0, 0, 1}}
      assert %{kind: :local} = Tailnet.identity(conn)
    end

    test "loopback conn with XFF resolves the forwarded address" do
      ip = uniq_tailnet_ip()
      ip_str = ip |> :inet.ntoa() |> to_string()

      put_whois(fn ^ip_str -> {:ok, %{"UserProfile" => %{"LoginName" => "fwd@example.com"}}} end)

      conn =
        %{Plug.Test.conn(:get, "/") | remote_ip: {127, 0, 0, 1}}
        |> Plug.Conn.put_req_header("x-forwarded-for", ip_str)

      assert %{login: "fwd@example.com", kind: :tailnet} = Tailnet.identity(conn)
    end

    test "a direct (non-loopback) peer cannot choose its identity via XFF" do
      # Attacker on 192.168.* sends a forged XFF naming a tailnet IP: the
      # header must be ignored and the real peer used, yielding no identity.
      conn =
        %{Plug.Test.conn(:get, "/") | remote_ip: {192, 168, 1, 66}}
        |> Plug.Conn.put_req_header("x-forwarded-for", "100.100.1.1")

      assert Tailnet.identity(conn) == nil
    end
  end

  describe "authorized?/1" do
    test "everything passes with enforcement off" do
      set_auth(:off)
      assert Tailnet.authorized?(nil)
      assert Tailnet.authorized?(%{login: "anyone", kind: :tailnet, node: nil})
    end

    test "required mode rejects missing identity" do
      set_auth(:required)
      refute Tailnet.authorized?(nil)
    end

    test "required mode always allows local" do
      set_auth(:required, ["only@example.com"])
      assert Tailnet.authorized?(%{login: "local", kind: :local, node: nil})
    end

    test "required mode with empty admin list allows any tailnet identity" do
      set_auth(:required)
      assert Tailnet.authorized?(%{login: "anyone@example.com", kind: :tailnet, node: nil})
    end

    test "required mode with admin list enforces membership" do
      set_auth(:required, ["mp@example.com"])
      assert Tailnet.authorized?(%{login: "mp@example.com", kind: :tailnet, node: nil})
      refute Tailnet.authorized?(%{login: "intruder@example.com", kind: :tailnet, node: nil})
    end
  end
end
