defmodule GiTF.Web.IdleStopControllerTest do
  @moduledoc "The Catwalk's keep-awake button sets a bounded override, never a permanent one."
  use GiTF.StoreCase
  import Phoenix.ConnTest

  alias GiTF.IdleStop
  alias GiTF.Web.IdleStopController

  setup do
    prev = System.get_env("GITF_HOME")
    dir = Path.join(System.tmp_dir!(), "gitf_hold_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    System.put_env("GITF_HOME", dir)

    on_exit(fn ->
      File.rm_rf!(dir)
      if prev, do: System.put_env("GITF_HOME", prev), else: System.delete_env("GITF_HOME")
    end)

    :ok
  end

  defp hold(minutes) do
    conn = build_conn(:post, "/dashboard/idle-stop/hold", %{"minutes" => minutes})
    IdleStopController.hold(conn, %{"minutes" => minutes})
  end

  test "holds the box for at least the requested minutes from now, and it expires" do
    conn = hold(60)
    assert conn.status == 200
    override = IdleStop.active()
    assert override.idle_minutes >= 60
    assert DateTime.diff(override.expires_at, DateTime.utc_now(), :minute) in 59..60
    assert override.reason =~ "Catwalk"
  end

  test "rejects a hold outside the bounds" do
    assert hold(2).status == 422
    assert hold(100_000).status == 422
    assert IdleStop.active() == nil
  end

  test "a hold that changed nothing says so, instead of claiming it set one" do
    assert hold(240).status == 200
    conn = hold(60)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)["data"]
    assert body["outcome"] == "kept"

    # The expiry reported is the four hours actually in force, not the hour
    # this request asked for.
    {:ok, until, _} = DateTime.from_iso8601(body["until"])
    assert DateTime.diff(until, DateTime.utc_now(), :minute) >= 239
  end

  test "a hold can be given back without an MCP client" do
    assert hold(240).status == 200
    assert IdleStop.active() != nil

    conn = build_conn(:post, "/dashboard/idle-stop/release", %{})
    conn = IdleStopController.release(conn, %{})

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["data"]["released"] == true
    assert IdleStop.active() == nil
  end

  test "releasing when nothing is held is harmless and says so" do
    conn = IdleStopController.release(build_conn(:post, "/dashboard/idle-stop/release", %{}), %{})
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["data"]["released"] == false
  end

  test "every hold is announced, with what it actually did" do
    # The relay listens for this to settle a sleep warning already posted
    # in Discord — the only way a Catwalk or MCP hold can reach one.
    ref = make_ref()
    me = self()

    :telemetry.attach(
      "hold-test-#{inspect(ref)}",
      [:gitf, :idle_stop, :held],
      fn _e, _m, meta, _ -> send(me, {:held, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("hold-test-#{inspect(ref)}") end)

    hold(240)
    assert_receive {:held, %{outcome: :set, reason: reason}}
    assert reason =~ "Catwalk"

    hold(60)
    assert_receive {:held, %{outcome: :kept}}
  end
end
