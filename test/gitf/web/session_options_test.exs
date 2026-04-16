defmodule GiTF.Web.SessionOptionsTest do
  use ExUnit.Case, async: false

  alias GiTF.Web.SessionOptions

  setup do
    # Save and restore endpoint config so tests don't leak
    original_web = Application.get_env(:gitf, GiTF.Web.Endpoint, [])
    original_dashboard = Application.get_env(:gitf, GiTF.Dashboard.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:gitf, GiTF.Web.Endpoint, original_web)
      Application.put_env(:gitf, GiTF.Dashboard.Endpoint, original_dashboard)
    end)

    :ok
  end

  describe "for_endpoint/1 with runtime config" do
    test "secure: true is read from runtime config" do
      Application.put_env(:gitf, GiTF.Web.Endpoint,
        session_signing_salt: "test_salt",
        session_secure: true
      )

      opts = SessionOptions.for_endpoint(GiTF.Web.Endpoint)

      assert opts[:secure] == true
      assert opts[:signing_salt] == "test_salt"
    end

    test "secure: false is read from runtime config" do
      Application.put_env(:gitf, GiTF.Web.Endpoint,
        session_signing_salt: "test_salt",
        session_secure: false
      )

      opts = SessionOptions.for_endpoint(GiTF.Web.Endpoint)

      assert opts[:secure] == false
    end

    test "signing_salt from runtime overrides env-var fallback" do
      Application.put_env(:gitf, GiTF.Web.Endpoint, session_signing_salt: "runtime_salt")

      opts = SessionOptions.for_endpoint(GiTF.Web.Endpoint)

      assert opts[:signing_salt] == "runtime_salt"
    end

    test "dashboard endpoint uses its own key" do
      Application.put_env(:gitf, GiTF.Dashboard.Endpoint, session_signing_salt: "dash_salt")

      opts = SessionOptions.for_endpoint(GiTF.Dashboard.Endpoint)

      assert opts[:key] == "_hive_dashboard"
      assert opts[:signing_salt] == "dash_salt"
    end

    test "web endpoint uses its own key" do
      Application.put_env(:gitf, GiTF.Web.Endpoint, session_signing_salt: "web_salt")

      opts = SessionOptions.for_endpoint(GiTF.Web.Endpoint)

      assert opts[:key] == "_gitf_key"
    end

    test "always sets http_only and same_site" do
      Application.put_env(:gitf, GiTF.Web.Endpoint, session_signing_salt: "x")

      opts = SessionOptions.for_endpoint(GiTF.Web.Endpoint)

      assert opts[:http_only] == true
      assert opts[:same_site] == "Lax"
      assert opts[:store] == :cookie
    end
  end
end
