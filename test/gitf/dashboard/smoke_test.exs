defmodule GiTF.Dashboard.SmokeTest do
  @moduledoc """
  Minimal smoke test to verify the dashboard boots and serves HTML.

  This complements the more thorough EndpointTest by verifying the most
  basic contract: the dashboard starts, responds to GET /, and returns
  HTML that identifies itself as the GiTF dashboard.
  """
  use ExUnit.Case, async: false

  @moduletag :dashboard

  setup_all do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    # Ensure Archive is running
    unless Process.whereis(GiTF.Archive) do
      tmp_dir = Path.join(System.tmp_dir!(), "gitf_test_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      GiTF.Archive.start_link(data_dir: tmp_dir)
    end

    # Ensure the Dashboard.Endpoint has required config
    current_config = Application.get_env(:gitf, GiTF.Dashboard.Endpoint, [])

    unless Keyword.has_key?(current_config, :secret_key_base) do
      config =
        Keyword.merge(current_config,
          secret_key_base:
            "test_secret_key_base_at_least_64_bytes_long_for_phoenix_endpoint_testing_abcdefghij",
          pubsub_server: GiTF.PubSub,
          live_view: [signing_salt: "gitf_dashboard_test_salt"]
        )

      Application.put_env(:gitf, GiTF.Dashboard.Endpoint, config)
    end

    # Start Dashboard.Endpoint if not running
    case Process.whereis(GiTF.Dashboard.Endpoint) do
      nil ->
        {:ok, _} = GiTF.Dashboard.Endpoint.start_link([])

      _pid ->
        :ok
    end

    :ok
  end

  test "dashboard returns 200 OK with GiTF HTML" do
    conn =
      :get
      |> Plug.Test.conn("/")
      |> GiTF.Dashboard.Endpoint.call(GiTF.Dashboard.Endpoint.init([]))

    assert conn.status == 200
    assert String.contains?(conn.resp_body, "GiTF")
    assert String.contains?(conn.resp_body, "<html")
  end

  test "response includes navigation links" do
    conn =
      :get
      |> Plug.Test.conn("/")
      |> GiTF.Dashboard.Endpoint.call(GiTF.Dashboard.Endpoint.init([]))

    body = conn.resp_body
    assert String.contains?(body, "Overview")
    assert String.contains?(body, "Missions")
    assert String.contains?(body, "Ghosts")
    assert String.contains?(body, "Costs")
    assert String.contains?(body, "Links")
  end
end
