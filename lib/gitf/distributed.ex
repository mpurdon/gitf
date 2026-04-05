defmodule GiTF.Distributed do
  @moduledoc """
  Foundation for distributed GiTF operations.

  Provides node discovery, role management, and cluster-aware execution primitives.
  Allows the GiTF to scale across multiple machines (e.g. "Majors" vs "Workers").
  """

  require Logger

  @doc """
  Returns the current node name.
  """
  def node_name, do: Node.self()

  @doc """
  Returns true if the node is connected to a cluster.
  """
  def clustered?, do: Node.list() != []

  @doc """
  Connects to a remote node.
  """
  def connect(node_name) do
    Node.connect(node_name)
  end

  @doc """
  Returns a list of all nodes in the cluster (including self).
  """
  def members do
    [Node.self() | Node.list()]
  end

  @doc """
  Executes a function on all nodes in the cluster.
  Returns a map of {node, result}.
  """
  def broadcast_exec(module, fun, args \\ []) do
    {results, _} = :rpc.multicall(members(), module, fun, args)
    Enum.zip(members(), results) |> Enum.into(%{})
  end

  @doc """
  Spawns a task on the least loaded node.
  (Simple implementation: random node for now, can be improved with load metrics)
  """
  def spawn_on_cluster(fun) do
    target = Enum.random(members())
    Node.spawn(target, fun)
  end
end
