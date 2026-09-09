defmodule GiTF.Cabinet.FleetTest do
  @moduledoc """
  The fleet's memory. EC2 knows a box's state and its last launch, but
  NOT when it stopped — an idle-stop is an instance-initiated shutdown
  whose transition reason carries no timestamp. `Fleet.observe/1` is
  where the Cabinet remembers what EC2 forgets.
  """
  use GiTF.StoreCase

  alias GiTF.Cabinet.{Activity, Fleet, Registry}

  defmodule Runner do
    @moduledoc false
    def ec2(["describe-instances" | _]) do
      case Process.get(:box) || Application.get_env(:gitf, :test_box) do
        {state, launched} ->
          {Jason.encode!(%{"state" => state, "launched_at" => launched}), 0}

        :down ->
          {"Could not connect to the endpoint URL", 255}
      end
    end

    def ec2(["start-instances" | _] = args) do
      Application.put_env(:gitf, :test_ec2_calls, [
        args | Application.get_env(:gitf, :test_ec2_calls, [])
      ])

      {"", 0}
    end
  end

  setup do
    prior = Application.get_env(:gitf, :cabinet_ec2_runner)
    Application.put_env(:gitf, :cabinet_ec2_runner, Runner)
    Application.put_env(:gitf, :test_ec2_calls, [])

    on_exit(fn ->
      Application.put_env(:gitf, :cabinet_ec2_runner, prior)
      Application.delete_env(:gitf, :test_box)
    end)

    {:ok, m} =
      Registry.create(%{
        slug: "fleet-#{System.unique_integer([:positive])}",
        name: "Fleet",
        url: "http://127.0.0.1:1",
        instance_id: "i-test"
      })

    %{ministry: m}
  end

  defp box(state, launched \\ "2026-09-09T15:07:54+00:00"),
    do: Application.put_env(:gitf, :test_box, {state, launched})

  test "describe parses state and launch time; a failed call is unknown", %{ministry: m} do
    box("running")
    assert %{state: "running", launched_at: %DateTime{}} = Fleet.describe(m)
    assert Fleet.instance_state(m) == "running"

    Application.put_env(:gitf, :test_box, :down)
    assert Fleet.describe(m) == %{state: :unknown, launched_at: nil}
    assert Fleet.describe(%{instance_id: nil}).state == :unknown
  end

  test "observe remembers the state and when it began", %{ministry: m} do
    # A running box: since = its EC2 launch time, exact.
    box("running")
    observed = Fleet.observe(m)
    assert observed.box.state == "running"
    assert observed.box.state_since == observed.box.launched_at
    assert Registry.get(m.id).box.state == "running"

    # It idle-stops. EC2 has no stop time; the Cabinet's sighting is it.
    box("stopped")
    before = DateTime.utc_now()
    observed = Fleet.observe(Registry.get(m.id))
    assert observed.box.state == "stopped"
    assert DateTime.compare(observed.box.state_since, before) in [:gt, :eq]

    # The transition is the Cabinet's own activity, not an operator's.
    assert Enum.any?(
             Activity.list(),
             &(&1.actor == "cabinet" and &1.action == "observed" and &1.result == "stopped")
           )

    # Still stopped a tick later: since is unchanged, nothing new recorded.
    since = observed.box.state_since
    n = length(Activity.list())
    assert Fleet.observe(Registry.get(m.id)).box.state_since == since
    assert length(Activity.list()) == n
  end

  test "a box first seen asleep has no known since; an unknown answer is not remembered", %{
    ministry: m
  } do
    box("stopped")
    assert Fleet.observe(m).box.state_since == nil

    Application.put_env(:gitf, :test_box, :down)
    observed = Fleet.observe(Registry.get(m.id))
    assert observed.box.state == :unknown
    assert Registry.get(m.id).box.state == "stopped"
  end

  test "await_healthy gives up at the deadline", %{ministry: m} do
    assert {:error, :wake_timeout} = Fleet.await_healthy(m, 0)
  end
end
