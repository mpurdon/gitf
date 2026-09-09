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
    GiTF.Test.StoreHelper.ensure_endpoint()
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
