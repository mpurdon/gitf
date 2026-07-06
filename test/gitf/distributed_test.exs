defmodule GiTF.DistributedTest do
  use ExUnit.Case, async: false

  alias GiTF.Distributed

  test "self is always a cluster member" do
    assert Node.self() in Distributed.members()
  end

  test "register / whereis round-trips a pid in a cluster-wide group" do
    key = {:test_group, System.unique_integer([:positive])}

    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    :ok = Distributed.register(key, pid)

    assert pid in Distributed.whereis(key)
    assert Distributed.whereis_one(key) == pid

    send(pid, :stop)
    # Membership is auto-removed when the pid dies.
    Process.sleep(50)
    assert Distributed.whereis(key) == []
  end

  test "unregister removes a member" do
    key = {:test_group, System.unique_integer([:positive])}
    pid = spawn(fn -> Process.sleep(1_000) end)

    :ok = Distributed.register(key, pid)
    assert pid in Distributed.whereis(key)

    :ok = Distributed.unregister(key, pid)
    Process.sleep(20)
    refute pid in Distributed.whereis(key)
  end

  test "whereis_one returns nil for an empty group" do
    assert Distributed.whereis_one({:empty, System.unique_integer([:positive])}) == nil
  end

  test "broadcast_exec runs on every node and maps by node" do
    result = Distributed.broadcast_exec(:erlang, :node, [])
    assert result[Node.self()] == Node.self()
  end

  test "spawn_on_cluster runs the function (single-node = local)" do
    parent = self()
    ref = make_ref()
    Distributed.spawn_on_cluster(fn -> send(parent, {ref, :ran}) end)
    assert_receive {^ref, :ran}, 1_000
  end
end
