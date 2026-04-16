defmodule GiTF.Web.RuntimeSessionPlug do
  @moduledoc """
  Wraps `Plug.Session` to read session options from runtime config.

  `Plug.Session.init/1` runs at compile time and bakes in `secure:`
  and `signing_salt:`. This plug delays the init until first request,
  reading from `GiTF.Web.SessionOptions.for_endpoint/1`. Init result
  is cached in `:persistent_term`.

  Pass `endpoint:` in plug opts to identify which endpoint's config
  to read.

      plug GiTF.Web.RuntimeSessionPlug, endpoint: GiTF.Web.Endpoint
  """

  @behaviour Plug

  @impl Plug
  def init(opts) do
    Keyword.fetch!(opts, :endpoint)
  end

  @impl Plug
  def call(conn, endpoint) do
    session_opts = lookup_or_init(endpoint)
    Plug.Session.call(conn, session_opts)
  end

  defp lookup_or_init(endpoint) do
    key = {__MODULE__, endpoint}

    case :persistent_term.get(key, :missing) do
      :missing ->
        opts = GiTF.Web.SessionOptions.for_endpoint(endpoint)
        initialized = Plug.Session.init(opts)
        :persistent_term.put(key, initialized)
        initialized

      cached ->
        cached
    end
  end
end
