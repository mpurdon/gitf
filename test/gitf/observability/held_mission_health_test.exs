defmodule GiTF.Observability.HeldMissionHealthTest do
  @moduledoc """
  A mission holding for a person is the human being idle, not the factory.
  It must neither trip the zombie detector nor keep the box awake.
  (msn-629e74, 2026-09-08: twelve hours of 503 "unhealthy" and ~$0.40 of
  compute waiting on a design-treatment choice nobody had answered.)
  """
  use GiTF.StoreCase

  alias GiTF.Archive
  alias GiTF.Observability.Health

  # Old enough that "no op activity in 30 minutes" is true for it.
  defp stale_mission(phase) do
    {:ok, m} = GiTF.Missions.create(%{goal: "hold me"})
    old = DateTime.shift(DateTime.utc_now(), hour: -2)
    m = %{m | status: "active", current_phase: phase, updated_at: old, inserted_at: old}
    Archive.put(:missions, m)
    m
  end

  test "a mission at awaiting_input does not read as a zombie" do
    held = stale_mission("awaiting_input")
    assert Health.alive?([held])
  end

  test "a stale running mission still does" do
    running = stale_mission("implementation")
    # No ops exist in this store, so there is no recent op activity.
    refute Health.alive?([running])
  end

  test "the health endpoint reports held missions and idle when only held ones remain" do
    stale_mission("awaiting_approval")

    conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.dispatch(GiTF.Web.Endpoint, :get, "/api/v1/health")

    body = Jason.decode!(conn.resp_body)["data"]
    assert body["held_missions"] == 1
    assert body["active_missions"] == 1
    assert body["idle"] == true
    assert conn.status == 200
  end
end
