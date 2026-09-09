defmodule GiTF.Web.OriginTest do
  @moduledoc """
  A dashboard whose websocket origin is refused renders and then does
  nothing — the Cabinet shipped that way because its env file never got
  GITF_CHECK_ORIGIN. The configured server URL is allowed by construction.
  """
  use ExUnit.Case, async: false

  alias GiTF.Web.Origin

  test "the configured list is honoured, with wildcards and ports" do
    list = "https://factory.example.com,//*.ts.net,http://localhost:4000"
    assert Origin.allowed?(URI.parse("https://factory.example.com"), list)
    assert Origin.allowed?(URI.parse("https://gitf.tail1234.ts.net"), list)
    assert Origin.allowed?(URI.parse("http://localhost:4000"), list)
    refute Origin.allowed?(URI.parse("http://localhost:4001"), list)
    refute Origin.allowed?(URI.parse("http://factory.example.com"), list)
    refute Origin.allowed?(URI.parse("https://evil.example.com"), list)
  end

  test "the server url is an allowed origin even with nothing configured" do
    prior = GiTF.Config.Provider.all()
    GiTF.Config.Provider.replace(Map.put(prior, :server, %{url: "https://cabinet.example.com"}))

    try do
      assert Origin.allowed?(URI.parse("https://cabinet.example.com"), nil)
      assert Origin.allowed?(URI.parse("https://cabinet.example.com"), "true")
      refute Origin.allowed?(URI.parse("https://other.example.com"), nil)
    after
      GiTF.Config.Provider.replace(prior)
    end
  end
end
