defmodule GiTF.Web.SessionOptions do
  @moduledoc """
  Builds Plug.Session options from runtime endpoint config.

  Both `secure:` and `signing_salt:` MUST come from the same runtime
  source so that response cookies (set via Plug.Session) and
  WebSocket connect_info session reads use matching salts.

  Used by:
  - `GiTF.Web.RuntimeSessionPlug` for response cookie setting
  - LiveView socket `connect_info: [session: {Mod, fun, args}]` for
    WebSocket session decoding
  """

  @doc """
  Returns Plug.Session options for the given endpoint module.

  Reads `:session_signing_salt`, `:session_secure`, and `:session_key`
  from `Application.get_env(:gitf, endpoint, [])`. Falls back to
  module-specific defaults if missing.
  """
  @spec for_endpoint(module()) :: keyword()
  def for_endpoint(endpoint) do
    config = Application.get_env(:gitf, endpoint, [])
    defaults = defaults_for(endpoint)

    [
      store: :cookie,
      key: Keyword.get(config, :session_key, defaults.key),
      signing_salt: Keyword.get(config, :session_signing_salt) || defaults.salt,
      same_site: "Lax",
      http_only: true,
      secure: Keyword.get(config, :session_secure, defaults.secure)
    ]
  end

  defp defaults_for(GiTF.Web.Endpoint) do
    %{
      key: "_gitf_key",
      salt: System.get_env("SESSION_SIGNING_SALT") || dev_salt!("gitf_web_salt_dev"),
      secure: false
    }
  end

  defp defaults_for(GiTF.Dashboard.Endpoint) do
    %{
      key: "_hive_dashboard",
      salt: System.get_env("LIVE_VIEW_SIGNING_SALT") || dev_salt!("gitf_salt_dev"),
      secure: false
    }
  end

  defp dev_salt!(default) do
    if Application.get_env(:gitf, :env) == :prod do
      raise "session signing salt missing — runtime.exs must set :session_signing_salt"
    else
      default
    end
  end
end
