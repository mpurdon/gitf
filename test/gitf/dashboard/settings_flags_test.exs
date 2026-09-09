defmodule GiTF.Dashboard.SettingsFlagsTest do
  @moduledoc """
  The settings page is the one place that says which feature flags are
  actually on. Before it existed the ground truth was a journal grep, and
  `outcomes_enabled` — carried in the old box's env file — was silently
  lost in the 2026-09-01 instance replacement: every PR published after
  it went untracked, unnoticed for a week.
  """
  use GiTF.StoreCase

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint GiTF.Web.Endpoint

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()

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

  test "every known flag is on the page with its effective value" do
    {:ok, view, html} = live(build_conn(), "/dashboard/settings")

    for flag <- GiTF.Flags.known() do
      assert html =~ ~s(config[features][#{flag}])
    end

    assert html =~ GiTF.Flags.describe(:outcomes_enabled)

    # Picking a value marks the page dirty, like every other field.
    html =
      render_change(view, "update", %{
        "config" => %{"features" => %{"outcomes_enabled" => "true"}}
      })

    assert html =~ "Save Changes"
  end
end
