defmodule GiTF.Dashboard.CabinetMinistriesTest do
  @moduledoc """
  The Ministries view: the fleet as objects — state, how long it has
  been that way, when it sleeps — with wake / sleep / wake-and-open in
  place, and `/wake/:slug` as the bookmark for a factory found asleep.
  """
  use GiTF.StoreCase

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias GiTF.Cabinet.Registry

  @endpoint GiTF.Web.Endpoint

  defmodule Runner do
    @moduledoc false
    def ec2(["describe-instances" | _]) do
      {Jason.encode!(%{
         "state" => Application.get_env(:gitf, :test_box_state, "stopped"),
         "launched_at" => "2026-09-09T15:07:54+00:00"
       }), 0}
    end

    def ec2(["start-instances", "--instance-ids", id]) do
      Application.put_env(:gitf, :test_woken, [id | Application.get_env(:gitf, :test_woken, [])])
      {"", 0}
    end

    def ec2(_), do: {"", 0}
  end

  setup do
    GiTF.Test.StoreHelper.ensure_endpoint()
    prior_mode = Application.get_env(:gitf, :cabinet_mode, false)
    prior_runner = Application.get_env(:gitf, :cabinet_ec2_runner)
    Application.put_env(:gitf, :cabinet_mode, true)
    Application.put_env(:gitf, :cabinet_ec2_runner, Runner)
    Application.put_env(:gitf, :test_woken, [])
    Application.put_env(:gitf, :test_box_state, "stopped")

    on_exit(fn ->
      Application.put_env(:gitf, :cabinet_mode, prior_mode)
      Application.put_env(:gitf, :cabinet_ec2_runner, prior_runner)
    end)

    slug = "min-#{System.unique_integer([:positive])}"

    {:ok, m} =
      Registry.create(%{
        slug: slug,
        name: "Home Affairs",
        url: "http://127.0.0.1:1",
        instance_id: "i-#{slug}"
      })

    %{ministry: m}
  end

  test "the fleet view shows every box with its state and actions", %{ministry: m} do
    {:ok, view, _html} = live(build_conn(), "/")
    html = render_click(view, "view", %{"view" => "ministries"})

    assert html =~ "Home Affairs"
    assert html =~ m.slug
    assert html =~ "Stopped"
    assert html =~ "Last woke"
    assert html =~ "Sep 09 15:07Z"
    assert html =~ "Wake &amp; open"
    refute html =~ ">Sleep<"

    # Wake fires EC2 and is recorded against the operator.
    html = render_click(view, "wake", %{"id" => m.id})
    assert m.instance_id in Application.get_env(:gitf, :test_woken)
    assert html =~ "Waking #{m.slug}"
  end

  test "a running box offers Sleep and reports its health", %{ministry: m} do
    Application.put_env(:gitf, :test_box_state, "running")
    {:ok, view, _html} = live(build_conn(), "/")
    html = render_click(view, "view", %{"view" => "ministries"})

    assert html =~ "Running"
    assert html =~ ">Sleep<"
    # No factory answers at the url: the row says so instead of inventing numbers.
    assert html =~ "health unreachable"
    refute html =~ "Wake &amp; open"
    _ = m
  end

  test "/wake/:slug wakes the box and waits to forward", %{ministry: m} do
    {:ok, view, _html} = live(build_conn(), "/wake/#{m.slug}")
    html = render(view)

    assert m.instance_id in Application.get_env(:gitf, :test_woken)
    assert html =~ "Waking #{m.slug}"
    assert html =~ "Stay here"

    # Only one wake per visit, even across refreshes.
    send(view.pid, :refresh)
    render(view)
    assert length(Application.get_env(:gitf, :test_woken)) == 1

    html = render_click(view, "cancel_open", %{})
    refute html =~ "Stay here"
  end

  test "an unknown slug is a flash, not a crash" do
    {:ok, view, _html} = live(build_conn(), "/wake/nobody")
    assert render(view) =~ "No ministry called nobody"
  end
end
