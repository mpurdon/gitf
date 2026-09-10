defmodule GiTF.Web.Signature do
  @moduledoc """
  HMAC-SHA256 signature verification for inbound webhooks.

  Centralises the hex-encoded HMAC compare so each provider's
  controller (GitHub, Sentry, …) doesn't reinvent the timing-safe
  comparison. Providers vary in header name and prefix conventions
  (GitHub: `X-Hub-Signature-256: sha256=<hex>`; Sentry:
  `Sentry-Hook-Signature: <hex>`), but the verification primitive is
  identical.
  """

  @doc """
  Returns true when `provided` is a valid HMAC-SHA256 hex digest of
  `body` under `secret`. `provided` may include a `sha256=` prefix
  (GitHub-style) which is stripped before comparison.

  Empty/nil secrets and non-binary bodies fail closed.
  """
  @spec verify(binary() | nil, binary() | nil, binary() | nil) :: boolean()
  def verify(secret, provided, body) do
    with secret when is_binary(secret) and secret != "" <- secret,
         provided when is_binary(provided) and provided != "" <- provided,
         body when is_binary(body) <- body do
      stripped = strip_prefix(provided)
      expected = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
      Plug.Crypto.secure_compare(String.downcase(stripped), expected)
    else
      _ -> false
    end
  end

  @doc """
  GitHub-style check on a conn: `x-hub-signature-256` over the cached raw
  body. The Cabinet's two signed ingresses (GitHub webhooks, a ministry's
  Discord relay) share it, so a ministry's one secret covers both.
  """
  @spec valid?(Plug.Conn.t(), binary() | nil) :: boolean()
  def valid?(conn, secret) do
    provided = conn |> Plug.Conn.get_req_header("x-hub-signature-256") |> List.first()
    verify(secret, provided, conn.assigns[:raw_body])
  end

  @doc "The `x-hub-signature-256` header value for `body` under `secret`."
  @spec sign(binary(), binary()) :: String.t()
  def sign(body, secret) do
    "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)
  end

  defp strip_prefix("sha256=" <> rest), do: rest
  defp strip_prefix(other), do: other
end
