defmodule GiTF.IdleStop.WarningTest do
  @moduledoc """
  The sleep warning is the operator's last chance to hold a box. It must
  fire once per idle episode, inside the window, with the facts a button
  needs — and stay quiet when the box is busy or a hold moved the stop.
  """
  use GiTF.StoreCase

  alias GiTF.IdleStop.Warning

  setup do
    dir = Path.join(System.tmp_dir!(), "gitf_warn_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    prev = %{
      home: System.get_env("GITF_HOME"),
      idle: System.get_env("GITF_IDLE_STOP_MINUTES"),
      grace: System.get_env("GITF_IDLE_STOP_GRACE_MINUTES")
    }

    System.put_env("GITF_HOME", dir)
    System.put_env("GITF_IDLE_STOP_MINUTES", "5")
    System.put_env("GITF_IDLE_STOP_GRACE_MINUTES", "0")

    handler = "warning-test-#{:erlang.unique_integer([:positive])}"
    pid = self()

    :telemetry.attach(
      handler,
      [:gitf, :alert, :raised],
      fn _e, _m, meta, _c -> send(pid, {:alert, meta}) end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      File.rm_rf!(dir)

      for {k, v} <- [
            {"GITF_HOME", prev.home},
            {"GITF_IDLE_STOP_MINUTES", prev.idle},
            {"GITF_IDLE_STOP_GRACE_MINUTES", prev.grace}
          ] do
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end
    end)

    # A fresh quiet: nothing running, activity just now → stop in 5 min.
    GiTF.Observability.Activity.touch()
    :ok
  end

  test "an idle box inside the window raises idle_stop_imminent with the facts a button needs" do
    assert Warning.check() == :warned

    assert_receive {:alert, %{type: :idle_stop_imminent, severity: :high, data: data}}
    assert data.minutes_left in 4..5
    assert {:ok, _, _} = DateTime.from_iso8601(data.stop_at)
    assert {:ok, _, _} = DateTime.from_iso8601(data.idle_since)
    assert data.held_missions == 0
  end

  test "one warning per idle episode — the second check is deduplicated" do
    # The dedup table is the Observability process's; tests boot without it.
    GiTF.Observability.Alerts.init_dedup_table()
    assert Warning.check() == :warned
    assert_receive {:alert, %{type: :idle_stop_imminent}}
    assert Warning.check() == :warned
    refute_receive {:alert, %{type: :idle_stop_imminent}}, 200
  end

  test "a hold moves the stop out of the window and the warning goes quiet" do
    {:ok, _} = GiTF.IdleStop.hold(120)
    assert Warning.check() == :quiet
    refute_receive {:alert, _}, 200
  end

  test "a running mission means no countdown at all" do
    {:ok, _} =
      GiTF.Archive.insert(:missions, %{
        name: "busy",
        status: "active",
        current_phase: "implementation",
        sector_id: "s",
        artifacts: %{},
        ops: []
      })

    assert Warning.check() == :quiet
  end
end
