defmodule GiTF.Missions.AwaitingAdmissionTest do
  @moduledoc """
  A mission nobody has started is not work.

  One forgotten `create_mission` used to count as running. `/health` then
  reported the box stalled — a running mission with no op activity — and
  the idle-stop script, which resets its countdown on a stalled daemon,
  never powered it off. Found by a probe mission during the drain
  acceptance test on 2026-09-21.

  The dangerous direction is the opposite one, and it gets the most tests:
  a mission that HAS started must never read as idle, even when its stored
  status is still the stale "pending" that `derive_status/1` exists for.
  """
  use GiTF.StoreCase

  alias GiTF.{Archive, Missions}
  alias GiTF.Observability.Health

  setup do
    prev = Application.get_env(:gitf, :aramaki_enabled)
    on_exit(fn -> Application.put_env(:gitf, :aramaki_enabled, prev) end)
    Application.put_env(:gitf, :aramaki_enabled, false)
    :ok
  end

  defp mission(attrs) do
    {:ok, m} =
      Archive.insert(
        :missions,
        Map.merge(
          %{name: "m", goal: "g", status: "pending", current_phase: "pending", artifacts: %{}},
          attrs
        )
      )

    m
  end

  test "a mission an operator created but never started is not running" do
    m = mission(%{})

    assert Missions.awaiting_admission?(m)
    refute Missions.running?(m)
  end

  test "a started mission with a STALE pending status is still running" do
    # The case that would power a box off mid-mission. The stored status can
    # lag behind the phase; liveness reads the raw Archive.
    for phase <- ~w(triage research design implementation validation) do
      m = mission(%{status: "pending", current_phase: phase})

      refute Missions.awaiting_admission?(m), "#{phase} read as never-started"
      assert Missions.running?(m), "#{phase} with a stale pending status read as idle"
    end
  end

  test "a pending mission Aramaki will start itself is work" do
    Application.put_env(:gitf, :aramaki_enabled, true)
    m = mission(%{source: "github_issue"})

    refute Missions.awaiting_admission?(m)
    assert Missions.running?(m)
  end

  test "the same mission with Aramaki off waits for a person" do
    m = mission(%{source: "github_issue"})

    assert Missions.awaiting_admission?(m)
    refute Missions.running?(m)
  end

  test "an unstarted mission leaves the box idle and does not look stalled" do
    m = mission(%{})

    %{idle: idle, running: running, held: held} = Health.idle_state()

    assert idle
    assert running == []
    # Counted as waiting on a person, which it is.
    assert Enum.any?(held, &(&1.id == m.id))
    refute Health.zombie?([m])
    refute Health.stuck?(m)
  end
end
