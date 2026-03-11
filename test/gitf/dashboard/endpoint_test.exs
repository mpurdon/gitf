defmodule GiTF.Dashboard.EndpointTest do
  use ExUnit.Case, async: false

  @moduletag :dashboard

  setup_all do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    # Ensure Archive is running (use the app's store)
    unless Process.whereis(GiTF.Archive) do
      tmp_dir = Path.join(System.tmp_dir!(), "gitf_dashboard_test_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      GiTF.Archive.start_link(data_dir: tmp_dir)
    end

    # Ensure the Dashboard.Endpoint has required config
    current_config = Application.get_env(:gitf, GiTF.Dashboard.Endpoint, [])
    unless Keyword.has_key?(current_config, :secret_key_base) do
      config = Keyword.merge(current_config, [
        secret_key_base: "test_secret_key_base_at_least_64_bytes_long_for_phoenix_endpoint_testing_abcdefghij",
        pubsub_server: GiTF.PubSub,
        live_view: [signing_salt: "gitf_dashboard_test_salt"]
      ])
      Application.put_env(:gitf, GiTF.Dashboard.Endpoint, config)
    end

    # Stop and start Dashboard.Endpoint to pick up the config
    GiTF.Test.StoreHelper.safe_stop(GiTF.Dashboard.Endpoint)
    {:ok, _} = GiTF.Dashboard.Endpoint.start_link([])

    :ok
  end

  describe "endpoint" do
    test "starts successfully" do
      assert Process.whereis(GiTF.Dashboard.Endpoint) != nil
    end

    test "serves the overview page at /" do
      conn = request(:get, "/")

      assert conn.status == 200
      assert String.contains?(conn.resp_body, "GiTF Dashboard")
      assert String.contains?(conn.resp_body, "Dashboard Overview")
    end

    test "serves the missions page at /missions" do
      conn = request(:get, "/missions")

      assert conn.status == 200
      assert String.contains?(conn.resp_body, "Quests")
    end

    test "serves the ghosts page at /ghosts" do
      conn = request(:get, "/ghosts")

      assert conn.status == 200
      assert String.contains?(conn.resp_body, "Bee Agents")
    end

    test "serves the costs page at /costs" do
      conn = request(:get, "/costs")

      assert conn.status == 200
      assert String.contains?(conn.resp_body, "Cost Tracking")
    end

    test "serves the links page at /links" do
      conn = request(:get, "/links")

      assert conn.status == 200
      assert String.contains?(conn.resp_body, "Link Messages")
    end

    test "includes CDN script tags for LiveView JS" do
      conn = request(:get, "/")

      assert String.contains?(conn.resp_body, "phoenix.min.js")
      assert String.contains?(conn.resp_body, "phoenix_live_view.min.js")
      assert String.contains?(conn.resp_body, "LiveSocket")
    end

    test "includes CSRF meta tag" do
      conn = request(:get, "/")

      assert String.contains?(conn.resp_body, "csrf-token")
    end

    test "includes inline CSS (no external stylesheet)" do
      conn = request(:get, "/")

      assert String.contains?(conn.resp_body, "<style>")
      assert String.contains?(conn.resp_body, "#0d1117")
    end
  end

  describe "router" do
    test "defines expected route paths" do
      routes = Phoenix.Router.routes(GiTF.Dashboard.Router)
      paths = Enum.map(routes, & &1.path)

      assert "/" in paths
      assert "/missions" in paths
      assert "/ghosts" in paths
      assert "/costs" in paths
      assert "/links" in paths
    end

    test "all routes are LiveView routes" do
      routes = Phoenix.Router.routes(GiTF.Dashboard.Router)

      for route <- routes do
        assert route.plug == Phoenix.LiveView.Plug,
               "expected #{route.path} to use LiveView.Plug, got #{inspect(route.plug)}"
      end
    end
  end

  # -- Helpers ----------------------------------------------------------------

  defp request(method, path) do
    method
    |> Plug.Test.conn(path)
    |> GiTF.Dashboard.Endpoint.call(GiTF.Dashboard.Endpoint.init([]))
  end
end
