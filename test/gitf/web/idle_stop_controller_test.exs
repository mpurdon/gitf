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
end
