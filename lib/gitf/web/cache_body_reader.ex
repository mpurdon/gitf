defmodule GiTF.Web.CacheBodyReader do
  @moduledoc """
  Plug body reader that stashes a copy of the raw request body on
  `conn.assigns[:raw_body]` when the path is under a webhook prefix.

  Webhook signature verification (HMAC-SHA256) needs the byte-exact body
  before JSON parsing, but `Plug.Parsers` consumes the body stream. This
  reader keeps both: parsers still get the parsed JSON, and the raw bytes
  remain accessible for signature checks.

  Non-webhook requests pay no extra cost — the cache is only populated
  when the path matches.
  """

  @prefixes ["/api/v1/webhooks"]

  @spec read_body(Plug.Conn.t(), keyword()) :: {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, maybe_cache(conn, body)}

      other ->
        other
    end
  end

  defp maybe_cache(conn, body) do
    if Enum.any?(@prefixes, &String.starts_with?(conn.request_path, &1)) do
      Plug.Conn.assign(conn, :raw_body, body)
    else
      conn
    end
  end
end
