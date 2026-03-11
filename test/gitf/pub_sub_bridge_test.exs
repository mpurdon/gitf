defmodule GiTF.PubSubBridgeTest do
  use ExUnit.Case, async: false

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    # Ensure PubSubBridge is running. If it was killed by another test's cleanup
    # or lost its PubSub connection, restart it.
    unless Process.whereis(GiTF.PubSubBridge) && Process.alive?(Process.whereis(GiTF.PubSubBridge)) do
      try do
        Supervisor.terminate_child(GiTF.Supervisor, GiTF.PubSubBridge)
        Supervisor.delete_child(GiTF.Supervisor, GiTF.PubSubBridge)
      catch
        :exit, _ -> :ok
      end
      GiTF.Test.StoreHelper.safe_stop(GiTF.PubSubBridge)
      {:ok, _} = GiTF.PubSubBridge.start_link([])
    end

    # Reattach telemetry handlers in case they were detached
    GiTF.PubSubBridge.subscribe()
    :ok
  end

  test "broadcasts telemetry events to pubsub" do
    # Emit a test event
    GiTF.Telemetry.emit([:gitf, :ghost, :spawned], %{count: 1}, %{ghost_id: "test-ghost"})

    # Assert we receive it
    assert_receive {:gitf_event, payload}, 1000

    assert payload.event == "section.ghost.spawned"
    assert payload.measurements == %{count: 1}
    # PubSubBridge adds :node to metadata
    assert payload.metadata.ghost_id == "test-ghost"
    assert Map.has_key?(payload.metadata, :node)
    assert %DateTime{} = payload.timestamp
  end
end
