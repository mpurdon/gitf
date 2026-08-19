defmodule GiTF.DiskUsage do
  @moduledoc """
  Disk-usage report for the factory host: gitf's own data, the build
  infrastructure it maintains, and a per-sector / per-ghost / per-mission
  attribution of worktree space.

  Born from the 2026-08-19 disk-full incident: a 12G volume filled up and
  took SSM, git, and the daemon down at once, and the only way to learn
  what was eating the disk was shelling in. The answer ("gitf data ~1.6G,
  probe build cache + swapfiles ~10G") should have been one tool call.

  Sizes are measured with `du -sk` (kilobytes) and reported in bytes;
  entries that cannot be measured report `nil` rather than lying with 0.
  """

  alias GiTF.Archive

  @doc "Full report: filesystem totals, infra dirs, sectors with per-ghost/mission attribution."
  @spec report() :: map()
  def report do
    home = System.user_home() || "/var/lib/gitf"

    %{
      filesystem: filesystem(home),
      infra: infra(home),
      sectors: sectors(),
      swapfiles: swapfiles()
    }
  end

  # -- filesystem --------------------------------------------------------------

  defp filesystem(path) do
    case safe_cmd("df", ["-Pk", path]) do
      {out, 0} ->
        case out |> String.split("\n", trim: true) |> List.last() |> String.split() do
          [_dev, total_k, used_k, avail_k | _] ->
            %{
              total_bytes: kb_to_bytes(total_k),
              used_bytes: kb_to_bytes(used_k),
              available_bytes: kb_to_bytes(avail_k)
            }

          _ ->
            %{total_bytes: nil, used_bytes: nil, available_bytes: nil}
        end

      _ ->
        %{total_bytes: nil, used_bytes: nil, available_bytes: nil}
    end
  end

  # -- infra dirs --------------------------------------------------------------

  # The big non-mission consumers an operator needs to see before blaming
  # mission data: build caches for the runtime probe, package registries,
  # and the store itself.
  defp infra(home) do
    [
      cargo_target: System.get_env("CARGO_TARGET_DIR") || Path.join(home, "cargo-target"),
      cargo_home: Path.join(home, ".cargo"),
      npm_cache: Path.join(home, ".npm"),
      gitf_store: Path.join(home, ".gitf"),
      claude_home: Path.join(home, ".claude"),
      probes: Path.join(home, "probes")
    ]
    |> Map.new(fn {label, path} -> {label, %{path: path, bytes: dir_size(path)}} end)
  end

  # -- sectors / ghosts / missions --------------------------------------------

  defp sectors do
    Archive.all(:sectors)
    |> Enum.map(fn sector ->
      path = sector[:path]

      worktrees =
        if is_binary(path) do
          Path.join(path, "ghosts")
          |> list_subdirs()
          |> Enum.map(fn ghost_dir ->
            ghost_id = Path.basename(ghost_dir)

            %{
              ghost_id: ghost_id,
              mission_id: mission_of_ghost(ghost_id),
              bytes: dir_size(ghost_dir)
            }
          end)
        else
          []
        end

      %{
        id: sector.id,
        name: sector[:name],
        path: path,
        repo_git_bytes: if(is_binary(path), do: dir_size(Path.join(path, ".git"))),
        worktrees: worktrees,
        by_mission: rollup_by_mission(worktrees)
      }
    end)
  end

  defp rollup_by_mission(worktrees) do
    worktrees
    |> Enum.group_by(&(&1.mission_id || "unattributed"))
    |> Map.new(fn {mission_id, group} ->
      {mission_id, Enum.reduce(group, 0, fn w, acc -> acc + (w.bytes || 0) end)}
    end)
  end

  defp mission_of_ghost(ghost_id) do
    case Archive.find_one(:ops, fn o -> o[:ghost_id] == ghost_id end) do
      %{mission_id: mid} when is_binary(mid) -> mid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # -- swap --------------------------------------------------------------------

  defp swapfiles do
    for path <- Path.wildcard("/swapfile*"),
        %File.Stat{size: size} <- [safe_stat(path)] do
      %{path: path, bytes: size}
    end
  end

  defp safe_stat(path) do
    case File.stat(path) do
      {:ok, stat} -> stat
      _ -> nil
    end
  end

  # -- helpers -----------------------------------------------------------------

  @doc false
  # Public for tests: du -sk on a directory, bytes or nil.
  def dir_size(path) do
    if File.dir?(path) do
      case safe_cmd("du", ["-sk", path]) do
        {out, 0} ->
          out |> String.split() |> List.first() |> kb_to_bytes()

        _ ->
          nil
      end
    else
      nil
    end
  end

  defp list_subdirs(path) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(path, &1))
        |> Enum.filter(&File.dir?/1)

      _ ->
        []
    end
  end

  defp kb_to_bytes(nil), do: nil

  defp kb_to_bytes(kb) when is_binary(kb) do
    case Integer.parse(kb) do
      {n, _} -> n * 1024
      :error -> nil
    end
  end

  # du on a large tree can take a while; bound it so a report can't hang
  # the caller.
  # The rescue belongs INSIDE the task: a missing binary raises in the
  # spawned process, where an outer rescue never sees it (it arrives as an
  # EXIT and kills the caller).
  defp safe_cmd(cmd, args) do
    task =
      Task.async(fn ->
        try do
          System.cmd(cmd, args, stderr_to_stdout: true)
        rescue
          _ -> {"error", 1}
        catch
          _, _ -> {"error", 1}
        end
      end)

    case Task.yield(task, 30_000) || Task.shutdown(task, 1_000) do
      {:ok, result} -> result
      _ -> {"timeout", 1}
    end
  end
end
