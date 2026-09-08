defmodule GiTF.Observability.HeldMissionHealthTest do
  @moduledoc """
  A mission holding for a person is the human being idle, not the factory
  (msn-629e74). It is not running, not stuck, not a zombie, and does not
  keep the box awake.
  """
  use GiTF.StoreCase
  import Phoenix.ConnTest

  alias GiTF.Archive
  alias GiTF.Missions
  alias GiTF.Observability.Health

  @endpoint GiTF.Web.Endpoint

  # A persisted mission at `phase`, `status: "active"` as transition_phase/3
  # sets it, quiet for two hours.
  defp mission!(phase) do
    {:ok, m} = Missions.create(%{goal: "hold me"})
    old = DateTime.shift(DateTime.utc_now(), hour: -2)
    m = %{m | status: "active", current_phase: phase, updated_at: old}
    Archive.put(:missions, m)
    m
  end

  test "running?/1 is non-terminal and not held" do
    assert Missions.running?(%{status: "active", current_phase: "implementation"})
    refute Missions.running?(%{status: "active", current_phase: "awaiting_input"})
    refute Missions.running?(%{status: "active", current_phase: "awaiting_approval"})
    refute Missions.running?(%{status: "completed", current_phase: "completed"})
  end

  test "a held mission is neither stuck nor a zombie; a quiet running one is both" do
    held = mission!("awaiting_input")
    refute Health.stuck?(held)
    refute Health.zombie?([held])

    running = mission!("implementation")
    assert Health.stuck?(running)
    # No ops exist for it, so there is no recent op activity.
    assert Health.zombie?([running])
    assert Health.zombie?([held, running])
  end

  test "idle?/2 needs no ghosts and no running missions; an unknown count is never idle" do
    assert Health.idle?(0, [])
    refute Health.idle?(0, [%{current_phase: "implementation"}])
    refute Health.idle?(1, [])
    refute Health.idle?(nil, [])
  end

  # The endpoint owns one thing: 503 only when the daemon is down, 200 with
  # the verdict in the body otherwise. Whether the Major is up in the test
  # VM is the environment's business (CI has caught it mid-restart), so the
  # mapping is asserted in both branches rather than assuming one.
  defp health_body(conn) do
    body = Jason.decode!(conn.resp_body)["data"]

    case body["status"] do
      "unhealthy" -> assert conn.status == 503
      _ -> assert conn.status == 200
    end

    body
  end

  test "/health counts a held mission as held, and idle (since the last activity) if it is the only one" do
    mission!("awaiting_approval")
    body = health_body(get(build_conn(), "/api/v1/health"))

    assert body["active_missions"] == 1 and body["held_missions"] == 1
    assert body["idle"] == true
    assert {:ok, _, _} = DateTime.from_iso8601(body["idle_since"])
  end

  test "/health reports a zombie as 'stalled' with a 200 — up, not down — and busy" do
    mission!("implementation")
    body = health_body(get(build_conn(), "/api/v1/health"))

    assert body["status"] in ["stalled", "unhealthy"]
    assert body["idle"] == false and body["idle_since"] == nil
  end

  # The idle countdown runs on the daemon's clock, not the timer's samples:
  # a mission that starts, runs and holds between two five-minute ticks
  # must still reset it (2026-09-08: it did not, and the box powered off
  # fifteen seconds after a fresh question was raised).
  test "a phase transition moves idle_since forward" do
    alias GiTF.Observability.Activity
    before = Activity.last_activity_at()
    Process.sleep(5)

    m = mission!("awaiting_input")
    {:ok, _} = Missions.transition_phase(m.id, "research", "test")

    assert DateTime.compare(Activity.last_activity_at(), before) == :gt
    assert Activity.idle_since(false) == nil
  end
end
