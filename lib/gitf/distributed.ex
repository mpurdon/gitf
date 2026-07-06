defmodule GiTF.Distributed do
  @moduledoc """
  Cluster-aware primitives for scaling GiTF across BEAM nodes.

  The process-per-ghost / DynamicSupervisor model is inherently distributable;
  the thing that blocks it today is *discovery* — the local `Registry` only
  knows about processes on its own node. This module provides the missing
  piece: cluster-wide **process groups** via Erlang's built-in `:pg` (no
  external dependency). `:pg` is location-transparent — a group's members can
  live on any connected node, and it degrades to trivially-correct behaviour on
  a single node (every member is local).

  Together with a formation library (`libcluster`) for node discovery and a
  partitioned/shared Archive, this is the foundation a distributed factory
  needs. Registrations here are the migration target for the node-local
  `Registry` usage (mission/ghost/lock lookup).
  """

  require Logger

  @scope GiTF.PG

  # -- Nodes -----------------------------------------------------------------

  @doc "This node's name."
  def node_name, do: Node.self()

  @doc "Whether this node is connected to any peers."
  def clustered?, do: Node.list() != []

  @doc "Connect to a peer node."
  def connect(node), do: Node.connect(node)

  @doc "All nodes in the cluster, including self."
  def members, do: [Node.self() | Node.list()]

  # -- Cluster-wide process groups (:pg) -------------------------------------

  @doc "Child spec that starts the `:pg` scope this module uses."
  def pg_child_spec do
    %{id: __MODULE__.PG, start: {:pg, :start_link, [@scope]}}
  end

  @doc """
  Registers `pid` (default `self()`) in the cluster-wide group `key`. The
  membership is visible from every connected node and is removed automatically
  when `pid` dies.
  """
  @spec register(term(), pid()) :: :ok
  def register(key, pid \\ self()) do
    :pg.join(@scope, key, pid)
  end

  @doc "Removes `pid` from group `key`."
  @spec unregister(term(), pid()) :: :ok | :not_joined
  def unregister(key, pid \\ self()) do
    :pg.leave(@scope, key, pid)
  end

  @doc "All pids registered under `key`, across the whole cluster."
  @spec whereis(term()) :: [pid()]
  def whereis(key), do: :pg.get_members(@scope, key)

  @doc "Pids registered under `key` on this node only."
  @spec whereis_local(term()) :: [pid()]
  def whereis_local(key), do: :pg.get_local_members(@scope, key)

  @doc "A single pid for `key` (first member), or nil."
  @spec whereis_one(term()) :: pid() | nil
  def whereis_one(key) do
    case whereis(key) do
      [pid | _] -> pid
      [] -> nil
    end
  end

  # -- Cluster-aware execution -----------------------------------------------

  @doc """
  Runs `module.fun(args)` on every node, returning `%{node => result}`. Uses
  `:erpc.multicall` (supervised, typed errors) rather than the legacy `:rpc`.
  """
  @spec broadcast_exec(module(), atom(), list()) :: %{node() => term()}
  def broadcast_exec(module, fun, args \\ []) do
    members()
    |> Enum.map(fn node ->
      result =
        try do
          :erpc.call(node, module, fun, args)
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      {node, result}
    end)
    |> Map.new()
  end

  @doc """
  Spawns `fun` on the least-loaded node (fewest running processes), so cluster
  work spreads instead of piling onto one node. Falls back to the local node
  when process counts can't be read.
  """
  @spec spawn_on_cluster((-> any())) :: pid()
  def spawn_on_cluster(fun) when is_function(fun, 0) do
    Node.spawn(least_loaded_node(), fun)
  end

  defp least_loaded_node do
    members()
    |> Enum.map(fn node -> {node, process_count(node)} end)
    |> Enum.min_by(fn {_node, count} -> count end, fn -> {Node.self(), 0} end)
    |> elem(0)
  end

  defp process_count(node) do
    case :erpc.call(node, :erlang, :system_info, [:process_count]) do
      n when is_integer(n) -> n
      _ -> :infinity
    end
  catch
    _, _ -> :infinity
  end
end
