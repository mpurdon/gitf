defmodule GiTF.DrainTest do
  @moduledoc """
  The quiesce half of a graceful shutdown.

  A drain exists to make "stop it when it is not busy" terminate. Without
  the gate, a box winding down could be handed a new mission by a webhook
  or an admission tick at any moment, and the wait for quiet would chase a
  moving target forever.
  """
  use GiTF.StoreCase

  alias GiTF.{Archive, Drain}
  alias GiTF.Major.Orchestrator

  setup do
    on_exit(&Drain.cancel/0)
    :ok
  end

  test "a drained box refuses new missions and says why" do
    assert Drain.preflight() == :ok

    {:ok, _} = Drain.begin(reason: "upgrading", actor: "discord:matt")

    assert Drain.draining?()
    assert Drain.preflight() == {:error, :draining}
    assert Drain.state().reason == "upgrading"
    assert Drain.state().actor == "discord:matt"
  end

  test "cancelling reopens the door, and cancelling nothing is harmless" do
    assert Drain.cancel() == :ok

    {:ok, _} = Drain.begin()
    assert Drain.cancel() == :ok

    refute Drain.draining?()
    assert Drain.preflight() == :ok
  end

  test "a forgotten drain opens by itself" do
    # The failure direction matters: an operator who drains a box and gets
    # distracted has a box that starts working again, not one that is
    # silently mute until someone reads the logs.
    {:ok, drain} = Drain.begin(minutes: 1)
    assert DateTime.diff(drain.expires_at, drain.since) == 60

    # Expiry is evaluated on read, so nothing has to sweep it.
    :persistent_term.put(
      {Drain, :state},
      %{drain | expires_at: DateTime.add(DateTime.utc_now(), -1, :second)}
    )

    refute Drain.draining?()
    assert Drain.preflight() == :ok
  end

  test "draining twice keeps the original since and takes the later expiry" do
    # "How long has this been winding down" must not reset because someone
    # tapped it again.
    {:ok, first} = Drain.begin(minutes: 5)
    {:ok, second} = Drain.begin(minutes: 60)

    assert second.since == first.since
    assert DateTime.compare(second.expires_at, first.expires_at) == :gt
  end

  test "the window is bounded however it is asked for" do
    for asked <- [9_999, 0, -5, nil, "an hour"] do
      Drain.cancel()
      {:ok, drain} = Drain.begin(minutes: asked)
      assert DateTime.diff(drain.expires_at, drain.since) <= 240 * 60
      assert DateTime.diff(drain.expires_at, drain.since) > 0
    end
  end

  test "the gate is on the one door every start goes through" do
    # start_quest/2 is where the webhook, Aramaki, the CLI, the HTTP API,
    # the dashboard, the idle sweeper and MCP all converge. Refusing here
    # is what makes the drain uncircumventable; a gate on any one caller
    # would be a gate on none of the others.
    {:ok, sector} = Archive.insert(:sectors, %{name: "drain-sector", path: "/tmp/drain-test"})

    {:ok, mission} =
      Archive.insert(:missions, %{
        name: "drain-mission",
        goal: "Work that must not begin on a box that is going down",
        sector_id: sector.id,
        status: "pending",
        current_phase: "pending",
        artifacts: %{},
        phase_jobs: %{}
      })

    {:ok, _} = Drain.begin(reason: "graceful stop")

    assert Orchestrator.start_quest(mission.id) == {:error, :draining}

    # And the mission is untouched — refused, not failed. It is still there
    # to start when the box comes back.
    assert Archive.get(:missions, mission.id).status == "pending"
  end
end
