defmodule GiTF.Tailnet do
  @moduledoc """
  Person-level identity for tailnet-only deployments.

  The dashboard is reachable only over Tailscale, which authenticates
  *devices* (WireGuard keys) but gives the application no idea which
  person is behind a request. This module closes that gap by resolving
  the caller's tailnet IP to a login via `tailscale whois`, so privileged
  actions carry a real actor instead of "dashboard_user".

  Trust model for the peer address:

    * Direct loopback with no X-Forwarded-For → a genuinely local caller
      (dev Mac, on-box curl): identity `local`.
    * Loopback WITH X-Forwarded-For → the request came through the
      co-located reverse proxy (Caddy): trust the first XFF entry.
    * Any other peer → use the socket address itself and IGNORE XFF —
      a client dialing the app port directly does not get to choose
      its identity by sending a header.

  Enforcement (`:tailnet_auth`):

    * `:off` (default) — resolve and attach identity, never block.
    * `:required` — requests without a resolvable identity, or with a
      login outside `:tailnet_admins` (when the list is non-empty), are
      rejected by `GiTF.Web.TailnetAuth`.

  Lookups are cached per-IP for #{div(300_000, 60_000)} minutes. A
  tailnet has a handful of devices, so `:persistent_term` churn is a few
  writes per hour — well under the global-GC concern threshold.
  """

  require Logger

  @cache_ttl_ms 300_000

  @type identity :: %{login: String.t(), kind: :local | :tailnet, node: String.t() | nil}

  @doc "Resolves the effective peer for a conn: {ip_tuple, xff_trusted?}."
  @spec peer_ip(Plug.Conn.t()) :: :inet.ip_address()
  def peer_ip(%Plug.Conn{} = conn) do
    with true <- loopback?(conn.remote_ip),
         [xff | _] <- Plug.Conn.get_req_header(conn, "x-forwarded-for"),
         first = xff |> String.split(",") |> List.first() |> String.trim(),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(first)) do
      ip
    else
      _ -> conn.remote_ip
    end
  end

  @doc "Resolves the caller's identity, or nil when the peer is neither local nor tailnet."
  @spec identity(Plug.Conn.t() | :inet.ip_address()) :: identity() | nil
  def identity(%Plug.Conn{} = conn) do
    # Loopback with XFF resolves through the proxy header; bare loopback is local.
    case {loopback?(conn.remote_ip), peer_ip(conn)} do
      {true, ip} when ip == conn.remote_ip -> %{login: "local", kind: :local, node: nil}
      {_, ip} -> identity(ip)
    end
  end

  def identity(ip) when is_tuple(ip) do
    cond do
      loopback?(ip) -> %{login: "local", kind: :local, node: nil}
      tailnet_ip?(ip) -> whois_cached(ip)
      true -> nil
    end
  end

  @doc "Whether requests without an authorized identity must be rejected."
  @spec enforcement() :: :off | :required
  def enforcement, do: Application.get_env(:gitf, :tailnet_auth, :off)

  @doc """
  Whether this identity may use the dashboard under the current policy.

  With enforcement `:off` everything is authorized. With `:required`:
  no identity → no; local → yes (an on-host caller already owns the box);
  empty admin list → any tailnet identity; otherwise login must be listed.
  """
  @spec authorized?(identity() | nil) :: boolean()
  def authorized?(identity) do
    case {enforcement(), identity} do
      {:off, _} -> true
      {:required, nil} -> false
      {:required, %{kind: :local}} -> true
      {:required, %{login: login}} -> authorized_login?(login)
    end
  end

  defp authorized_login?(login) do
    case Application.get_env(:gitf, :tailnet_admins, []) do
      [] -> true
      admins -> login in admins
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false

  # Tailscale CGNAT range 100.64.0.0/10 and its IPv6 ULA fd7a:115c:a1e0::/48.
  defp tailnet_ip?({100, b, _, _}) when b >= 64 and b <= 127, do: true
  defp tailnet_ip?({0xFD7A, 0x115C, 0xA1E0, _, _, _, _, _}), do: true
  defp tailnet_ip?(_), do: false

  defp whois_cached(ip) do
    key = {__MODULE__, :whois, ip}
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(key, nil) do
      {identity, at} when now - at < @cache_ttl_ms ->
        identity

      _ ->
        identity = whois(ip)
        # Cache nil too: an unresolvable peer shouldn't hammer the daemon.
        :persistent_term.put(key, {identity, now})
        identity
    end
  end

  defp whois(ip) do
    ip_str = ip |> :inet.ntoa() |> to_string()

    case whois_fun().(ip_str) do
      {:ok, %{} = data} ->
        login =
          get_in(data, ["UserProfile", "LoginName"]) ||
            data |> get_in(["Node", "Tags"]) |> List.wrap() |> List.first()

        node = get_in(data, ["Node", "ComputedName"])

        if is_binary(login) and login != "" do
          %{login: login, kind: :tailnet, node: node}
        else
          Logger.warning("tailscale whois for #{ip_str} returned no login")
          nil
        end

      :error ->
        nil
    end
  end

  # Injectable for tests: a fun (ip_string -> {:ok, decoded_json} | :error).
  defp whois_fun do
    Application.get_env(:gitf, :tailnet_whois_fun, &default_whois/1)
  end

  defp default_whois(ip_str) do
    case System.find_executable("tailscale") do
      nil ->
        Logger.warning("tailnet identity unavailable: tailscale binary not on PATH")
        :error

      bin ->
        try do
          case System.cmd(bin, ["whois", "--json", ip_str], stderr_to_stdout: true) do
            {out, 0} ->
              case Jason.decode(out) do
                {:ok, data} -> {:ok, data}
                _ -> :error
              end

            {out, _} ->
              Logger.warning("tailscale whois #{ip_str} failed: #{String.slice(out, 0, 200)}")
              :error
          end
        rescue
          e ->
            Logger.warning("tailscale whois #{ip_str} raised: #{Exception.message(e)}")
            :error
        end
    end
  end
end
