defmodule GiTF.Web.DashboardTest do
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  @endpoint GiTF.Web.Endpoint

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    # The Web.Endpoint is started by the application supervisor.
    # Ensure it is alive and has its ETS table intact.
    endpoint_alive? =
      case Process.whereis(GiTF.Web.Endpoint) do
        nil -> false
        pid -> Process.alive?(pid)
      end

    ets_ok? =
      try do
        GiTF.Web.Endpoint.config(:pubsub_server)
        true
      rescue
        ArgumentError -> false
      end

    if !(endpoint_alive? and ets_ok?) do
      GiTF.Test.StoreHelper.safe_stop(GiTF.Web.Endpoint)
      Process.sleep(50)
      current = Application.get_env(:gitf, GiTF.Web.Endpoint, [])
      Application.put_env(:gitf, GiTF.Web.Endpoint, Keyword.put(current, :server, false))
      {:ok, _} = GiTF.Web.Endpoint.start_link([])
    end

    :ok
  end

  # The legacy Factory Floor moved off "/" when the Catwalk took the root.
  # It stays reachable at /floor for one release.
  test "the legacy factory floor still renders at /floor" do
    conn = Phoenix.ConnTest.build_conn()
    {:ok, _view, html} = live(conn, "/floor")
    assert html =~ "GiTF Control Plane"
    assert html =~ "Active Ghosts"
  end

  test "the root serves the Catwalk, not the factory floor" do
    conn = Phoenix.ConnTest.build_conn()
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "The Catwalk"
    refute html =~ "GiTF Control Plane"
  end
end
