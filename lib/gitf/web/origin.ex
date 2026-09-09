defmodule GiTF.Web.Origin do
  @moduledoc """
  The websocket origin check, fed by what the operator already told us.

  LiveView refuses socket connections from origins it was not told about,
  and the failure is silent from the browser's side: the page renders,
  nothing on it works. The Cabinet shipped exactly like that — its env
  file never got `GITF_CHECK_ORIGIN`, though its config carried
  `[server] url = "https://cabinet.ghostinthefactory.com"` all along.
  So the server URL is an allowed origin by construction, on top of the
  explicit `GITF_CHECK_ORIGIN` list (which still wins when set to
  `false`, handled in runtime.exs).
  """

  @doc """
  Whether a socket may connect from `uri`. `configured` is the raw
  `GITF_CHECK_ORIGIN` value (nil / "true" / a comma-separated list).
  """
  @spec allowed?(URI.t(), String.t() | nil) :: boolean()
  def allowed?(%URI{} = uri, configured) do
    Enum.any?(allowed_origins(configured), &origin_match?(&1, uri))
  end

  @doc "The origins that may connect: the configured list plus the server URL."
  def allowed_origins(configured) do
    (parse_list(configured) ++ [server_url()])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&URI.parse/1)
  end

  defp parse_list(list) when is_binary(list) and list not in ["", "true", "false"],
    do: String.split(list, ",", trim: true) |> Enum.map(&String.trim/1)

  defp parse_list(_), do: []

  defp server_url do
    case GiTF.Config.Provider.get([:server, :url]) do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Same shape as Phoenix's own check: host must match (with a `*.`
  # wildcard), scheme and port only when the allowed origin names them.
  defp origin_match?(%URI{host: nil}, _uri), do: false

  defp origin_match?(%URI{} = allowed, %URI{} = uri) do
    host_match?(allowed.host, uri.host) and
      allowed.scheme in [nil, uri.scheme] and
      (is_nil(allowed.port) or allowed.port == uri.port or default_port?(allowed))
  end

  defp host_match?("*." <> suffix, host) when is_binary(host),
    do: String.ends_with?(host, "." <> suffix)

  defp host_match?(allowed, host), do: allowed == host

  # URI.parse fills the default port for known schemes; an origin written
  # without a port means "the scheme's default", which is what a browser
  # sends too — so a filled default is not a constraint.
  defp default_port?(%URI{scheme: "https", port: 443}), do: true
  defp default_port?(%URI{scheme: "http", port: 80}), do: true
  defp default_port?(_), do: false
end
