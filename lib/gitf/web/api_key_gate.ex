defmodule GiTF.Web.ApiKeyGate do
  @moduledoc """
  Requires a valid `x-api-key` unless the request is local and the
  local-IP bypass is enabled. Extracted from the router so the factory
  router and the Cabinet router share ONE authentication seam — two
  copies of an auth check is how they drift.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    bypass_enabled? = Application.get_env(:gitf, :local_ip_bypass, false)
    trust_xff? = Application.get_env(:gitf, :trust_x_forwarded_for, false)

    remote_ip =
      if trust_xff? do
        case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
          [xff | _] ->
            xff
            |> String.split(",")
            |> List.first()
            |> String.trim()
            |> parse_ip(conn.remote_ip)

          _ ->
            conn.remote_ip
        end
      else
        conn.remote_ip
      end

    if bypass_enabled? and local_ip?(remote_ip) do
      conn
    else
      case Plug.Conn.get_req_header(conn, "x-api-key") do
        [key] when byte_size(key) > 0 ->
          if valid_api_key?(key) do
            conn
          else
            conn
            |> Plug.Conn.put_status(401)
            |> Phoenix.Controller.json(%{error: "invalid API key"})
            |> Plug.Conn.halt()
          end

        _ ->
          conn
          |> Plug.Conn.put_status(401)
          |> Phoenix.Controller.json(%{error: "API key required for non-local requests"})
          |> Plug.Conn.halt()
      end
    end
  end

  defp local_ip?({127, 0, 0, 1}), do: true
  defp local_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp local_ip?(_), do: false

  defp parse_ip(str, fallback) do
    case :inet.parse_address(String.to_charlist(str)) do
      {:ok, ip} -> ip
      _ -> fallback
    end
  end

  defp valid_api_key?(key) do
    case GiTF.Config.api_key() do
      nil -> false
      configured_key -> Plug.Crypto.secure_compare(key, configured_key)
    end
  end
end
