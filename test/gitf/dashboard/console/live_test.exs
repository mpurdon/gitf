defmodule GiTF.Dashboard.Console.LiveTest do
  @moduledoc """
  Every other Console test renders a page function directly, which is how a
  crash in the LiveView's own dispatch reached the box: `<.head>` was invoked
  with an enumerated list of attributes, the heads for the factory-side objects
  needed one more, and a deep link 500'd while every page test passed.

  These mount the real LiveView and walk it to each scope, so the assigns it
  actually builds are the assigns each head and page actually gets.
  """
  use GiTF.StoreCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias GiTF.Cabinet.Registry

  @endpoint GiTF.Web.Endpoint

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    unless Process.whereis(GiTF.Web.Endpoint) do
      current = Application.get_env(:gitf, GiTF.Web.Endpoint, [])
      Application.put_env(:gitf, GiTF.Web.Endpoint, Keyword.put(current, :server, false))
      {:ok, _} = GiTF.Web.Endpoint.start_link([])
    end

    {:ok, m} =
      Registry.create(%{
        slug: "home-affairs",
        name: "Home Affairs",
        url: "http://127.0.0.1:1",
        instance_id: "i-1"
      })

    {:ok, _} = Registry.update(m.id, &Map.put(&1, :box, %{state: "stopped"}))

    # The endpoint picks its router per request, so the Console's real routes —
    # and therefore handle_params, where the crash was — only exist in cabinet
    # mode. `live_isolated` cannot run handle_params at all, which is precisely
    # the part worth testing.
    prior = Application.get_env(:gitf, :cabinet_mode)
    Application.put_env(:gitf, :cabinet_mode, true)
    on_exit(fn -> Application.put_env(:gitf, :cabinet_mode, prior) end)

    :ok
  end

  defp mount! do
    {:ok, view, _html} = live(build_conn(), "/console")
    view
  end

  # Every scope the Console addresses, including the three that live on a
  # factory this test can never reach — which is the point: a cold link has to
  # render an explanation, not a 500.
  @scopes [
    "/console",
    "/console/activity",
    "/console/m/home-affairs",
    "/console/m/home-affairs/ruleset",
    "/console/m/home-affairs/registration",
    "/console/m/home-affairs/s/cora",
    "/console/m/home-affairs/msn/msn-7683ac",
    "/console/m/home-affairs/op/op-2"
  ]

  test "every scope renders" do
    view = mount!()

    for path <- @scopes do
      html = render_patch(view, path)
      assert html =~ "Cabinet", "#{path} rendered no chrome"
      refute html =~ "KeyError", "#{path} rendered an error into the page"
    end
  end

  test "every depth tab renders on every scope that offers one" do
    view = mount!()

    for path <- @scopes, tab <- ~w(overview evidence raw) do
      assert render_patch(view, "#{path}?t=#{tab}") =~ "Cabinet",
             "#{path} at depth #{tab} rendered no chrome"
    end
  end

  test "a deep link to a sleeping factory explains itself rather than failing" do
    view = mount!()
    html = render_patch(view, "/console/m/home-affairs/msn/msn-7683ac")

    assert html =~ "asleep"
    assert html =~ "/console/wake/home-affairs"
  end

  test "a link to a ministry that no longer exists lands somewhere useful" do
    view = mount!()

    for path <- ["/console/m/retired", "/console/m/retired/msn/msn-1", "/console/nonsense"] do
      assert render_patch(view, path) =~ "Cabinet"
    end
  end
end
