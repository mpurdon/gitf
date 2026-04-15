defmodule GiTF.Cluster.Formation do
  @moduledoc """
  Simple cluster formation utility.

  Allows nodes to connect by name and cookie without external dependencies
  like libcluster for now. Use for manual or script-based cluster joining.

  ## Usage

      # On Node A (Leader):
      iex --name major@192.168.1.10 --cookie secret -S mix

      # On Node B (Worker):
      iex --name worker1@192.168.1.11 --cookie secret -S mix
      iex> GiTF.Cluster.Formation.join("major@192.168.1.10")

  """

  require Logger

  @doc """
  Connects the current node to a cluster via a seed node.
  """
  def join(seed_node) when is_binary(seed_node) do
    node_atom = String.to_atom(seed_node)
    join(node_atom)
  end

  def join(seed_node) when is_atom(seed_node) do
    if Node.connect(seed_node) do
      Logger.info("Successfully joined cluster via #{seed_node}")
      :ok
    else
      Logger.error("Failed to connect to #{seed_node}. Check network/cookie.")
      {:error, :connection_failed}
    end
  end

  @doc """
  Returns the list of connected nodes.
  """
  def members do
    [Node.self() | Node.list()]
  end
end
