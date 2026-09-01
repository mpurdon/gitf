defmodule GiTF.Cabinet.ConsoleTest do
  @moduledoc """
  The Console's feature seams: validated registry edits, the activity
  feed, and policy-cell cycling driven the way a browser drives it.
  """

  use GiTF.StoreCase

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias GiTF.Cabinet.{Activity, Registry}

  @endpoint GiTF.Web.Endpoint

  defp ministry! do
    {:ok, m} =
      Registry.create(%{
        slug: "console-#{:erlang.unique_integer([:positive])}",
        name: "Console Test",
        url: nil
      })

    m
  end

  defp mount_console! do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    {:ok, view, _html} =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> live_isolated(GiTF.Dashboard.CabinetLive)

    view
  end

  describe "Registry.edit/2" do
    test "edits only editable fields and parses the cap" do
      m = ministry!()

      {:ok, updated} =
        Registry.edit(m.id, %{
          "name" => "Renamed",
          "cost_cap_usd" => "250.5",
          "url" => "  https://x.example  ",
          "slug" => "hax",
          "mode" => "off"
        })

      assert updated.name == "Renamed"
      assert updated.cost_cap_usd == 250.5
      assert updated.url == "https://x.example"
      # slug and mode are not editable through the form
      assert updated.slug == m.slug
      assert updated.mode == "normal"
    end

    test "refuses a cap that is not a number" do
      m = ministry!()
      assert {:error, {:invalid, msg}} = Registry.edit(m.id, %{"cost_cap_usd" => "lots"})
      assert msg =~ "not a number"
    end

    test "empty strings clear a field" do
      m = ministry!()
      {:ok, _} = Registry.edit(m.id, %{"url" => "https://x.example"})
      {:ok, updated} = Registry.edit(m.id, %{"url" => "   "})
      assert updated.url == nil
    end
  end

  describe "Activity" do
    test "records and lists newest first" do
      Activity.record("tester", "wake", "somewhere", "starting")
      Activity.record("tester", "stop", "somewhere", "stopping")

      [first | _] = Activity.list(5)
      assert first.action == "stop"
      assert first.actor == "tester"
    end
  end

  describe "the Console" do
    test "cycling a policy cell rewrites the JDM and the grid agrees" do
      m = ministry!()
      view = mount_console!()

      # rule 4 of the default ruleset: feature · any · any → queue
      render_click(view, "view", %{"view" => "policy"})
      html = render_click(view, "cycle_rule", %{"id" => m.id, "rule" => "4"})
      assert html =~ "Rule 4: drop"

      updated = Registry.get(m.id)
      assert %{"nodes" => _} = updated.rules

      # the same document still evaluates, and the changed row decides
      assert {:ok, %{"action" => "drop"}, %{rule: 4}} =
               GiTF.Cabinet.JDM.evaluate(updated.rules, %{
                 "class" => "feature",
                 "mode" => "normal",
                 "over_cap" => false
               })
    end

    test "registering a ministry through the form" do
      view = mount_console!()
      slug = "formed-#{:erlang.unique_integer([:positive])}"

      render_click(view, "view", %{"view" => "registry"})
      render_click(view, "edit", %{})

      html =
        render_submit(view, "save_ministry", %{
          "slug" => slug,
          "name" => "Formed",
          "cost_cap_usd" => "50"
        })

      assert html =~ "Formed"
      assert %{name: "Formed", cost_cap_usd: 50.0} = Registry.by_slug(slug)
    end
  end
end
