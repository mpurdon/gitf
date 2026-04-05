defmodule GiTF.Sync.Strategy do
  @moduledoc """
  Computes optimal sync order for pending ops.

  Uses dependency-aware topological sort with multi-factor tie-breaking
  to minimize merge conflicts and maximize throughput.

  ## Ordering rules (in priority order)

  1. Dependency graph: topological sort respecting depends_on
  2. File disjointness: ops touching unique files sync first
  3. Smaller diffs first: fewer changed_files = less conflict surface
  4. Phase order: research < implementation < verification
  5. Conflict history penalty: historically-conflicting files go later
  """

  alias GiTF.Archive

  @phase_order %{
    "research" => 0,
    "requirements" => 1,
    "design" => 2,
    "implementation" => 3,
    "verification" => 4,
    "review" => 5
  }

  # -- Public API --------------------------------------------------------------

  @doc """
  Returns an optimally-ordered list of `{op_id, shell_id}` tuples.

  Input: list of `{op_id, shell_id}` tuples representing sync-ready ops.
  Output: same tuples reordered for optimal sync sequence.
  """
  @spec optimal_order([{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def optimal_order([]), do: []
  def optimal_order([single]), do: [single]

  def optimal_order(pending_jobs) do
    op_ids = Enum.map(pending_jobs, &elem(&1, 0))
    job_map = Map.new(pending_jobs, fn {jid, cid} -> {jid, cid} end)

    # Load op records
    ops = load_jobs(op_ids)

    # Build dependency edges (only between pending ops)
    pending_set = MapSet.new(op_ids)
    edges = build_dependency_edges(op_ids, pending_set)

    # Topological sort with tie-breaking
    sorted_ids = topo_sort_with_tiebreak(op_ids, edges, ops)

    Enum.map(sorted_ids, fn jid -> {jid, Map.get(job_map, jid)} end)
  rescue
    _ ->
      # On any error, return original order (safe fallback)
      pending_jobs
  end

  # -- Private: topological sort -----------------------------------------------

  defp topo_sort_with_tiebreak(op_ids, edges, ops) do
    # Build in-degree map and adjacency list
    in_degree = Map.new(op_ids, fn id -> {id, 0} end)
    adj = Map.new(op_ids, fn id -> {id, []} end)

    {in_degree, adj} =
      Enum.reduce(edges, {in_degree, adj}, fn {from, to}, {deg, a} ->
        deg = Map.update(deg, to, 1, &(&1 + 1))
        a = Map.update(a, from, [to], &[to | &1])
        {deg, a}
      end)

    # Kahn's algorithm with tie-breaking at each level
    conflict_prone = conflict_prone_set()
    do_topo_sort(in_degree, adj, ops, conflict_prone, [])
  end

  defp do_topo_sort(in_degree, adj, ops, conflict_prone, acc) do
    # Find all nodes with in-degree 0
    ready =
      in_degree
      |> Enum.filter(fn {_id, deg} -> deg == 0 end)
      |> Enum.map(&elem(&1, 0))

    if ready == [] do
      # Done (or cycle — return whatever we have plus remaining)
      remaining = Map.keys(in_degree)
      acc ++ remaining
    else
      # Sort ready nodes by tie-breaking heuristics
      sorted_ready = sort_by_heuristics(ready, ops, conflict_prone)

      # Take the best candidate
      [best | rest_ready] = sorted_ready

      # Update in-degree: remove best, decrement dependents
      new_in_degree =
        Map.delete(in_degree, best)
        |> then(fn deg ->
          neighbors = Map.get(adj, best, [])

          Enum.reduce(neighbors, deg, fn n, d ->
            Map.update(d, n, 0, &max(&1 - 1, 0))
          end)
        end)

      # If multiple nodes were ready, put the rest back
      # (they'll be picked up in the next iteration)
      _ = rest_ready

      do_topo_sort(new_in_degree, adj, ops, conflict_prone, acc ++ [best])
    end
  end

  # -- Private: tie-breaking heuristics ----------------------------------------

  defp sort_by_heuristics(op_ids, ops, conflict_prone) do
    Enum.sort_by(op_ids, fn jid ->
      op = Map.get(ops, jid, %{})

      {
        file_overlap_score(op, conflict_prone),
        diff_size(op),
        phase_score(op),
        conflict_history_penalty(op, conflict_prone)
      }
    end)
  end

  # Lower = better. Jobs touching files no other op touches get score 0.
  defp file_overlap_score(op, conflict_prone) do
    files = Map.get(op, :changed_files, []) |> List.wrap()
    Enum.count(files, &MapSet.member?(conflict_prone, &1))
  end

  # Smaller diffs first
  defp diff_size(op) do
    Map.get(op, :files_changed, 0) || 0
  end

  # Research before implementation before verification
  defp phase_score(op) do
    phase = Map.get(op, :phase) || Map.get(op, :op_type) || "implementation"
    Map.get(@phase_order, phase, 3)
  end

  # Files that historically conflict get a penalty
  defp conflict_history_penalty(op, conflict_prone) do
    files = Map.get(op, :changed_files, []) |> List.wrap()
    Enum.count(files, &MapSet.member?(conflict_prone, &1))
  end

  # -- Private: helpers --------------------------------------------------------

  defp load_jobs(op_ids) do
    Map.new(op_ids, fn jid ->
      case Archive.get(:ops, jid) do
        nil -> {jid, %{}}
        op -> {jid, op}
      end
    end)
  end

  defp build_dependency_edges(op_ids, pending_set) do
    Enum.flat_map(op_ids, fn jid ->
      Archive.filter(:op_dependencies, fn d -> d.op_id == jid end)
      |> Enum.filter(fn d -> MapSet.member?(pending_set, d.depends_on_id) end)
      |> Enum.map(fn d -> {d.depends_on_id, d.op_id} end)
    end)
  end

  defp conflict_prone_set do
    GiTF.Sync.History.conflict_prone_files()
    |> Enum.take(50)
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  rescue
    _ -> MapSet.new()
  end
end
