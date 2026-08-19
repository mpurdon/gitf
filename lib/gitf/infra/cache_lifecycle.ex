defmodule GiTF.Infra.CacheLifecycle do
  @moduledoc """
  Maintains the shared build caches: verify, repair, and garbage-collect.

  The factory shares an npm cache and a cargo target dir across ghosts
  because cold builds are 25 minutes and warm ones are 90 seconds. Sharing
  without maintenance is how runs 21, 27 and 30 died: OOM-killed ghosts
  corrupted `~/.npm/_cacache`, `npm ci` kept exiting 0 while installing a
  broken TypeScript, and the resulting TS2318 errors were blamed on ghost
  code for three separate campaigns.

  Sandboxes now mount those caches as overlays (see
  `GiTF.Sandbox.Bubblewrap`), so a dying ghost cannot damage the shared
  copy. This module owns the other half: proving the copy is healthy and
  keeping it from eating the disk.

  Verification is deliberately about ARTIFACTS, not npm's own opinion:
  `npm cache verify` reported success on a cache whose typescript package
  was missing `lib.es5.d.ts`.
  """

  require Logger

  # A cargo target dir grows without bound (7.2GB before the first sweep).
  @cargo_target_max_gb 8
  @npm_cache_max_gb 2

  @doc """
  Verifies cache health. Returns `{:ok, report}` or `{:degraded, report}`;
  the report names each cache, its size, and what was found.
  """
  @spec verify() :: {:ok, map()} | {:degraded, map()}
  def verify do
    home = System.user_home() || "/var/lib/gitf"
    npm = Path.join(home, ".npm")
    cargo_target = System.get_env("CARGO_TARGET_DIR") || Path.join(home, "cargo-target")

    report = %{
      npm_cache: %{path: npm, bytes: dir_bytes(npm), healthy: npm_cache_healthy?(npm)},
      cargo_target: %{path: cargo_target, bytes: dir_bytes(cargo_target), healthy: true}
    }

    if report.npm_cache.healthy, do: {:ok, report}, else: {:degraded, report}
  end

  @doc """
  Verify, repair what is broken, and GC what is oversized.

  Safe to call on a live factory: repair only ever DELETES cache entries
  (they are re-downloadable by definition), never source or worktrees.
  """
  @spec maintain() :: {:ok, map()}
  def maintain do
    {status, report} = verify()

    repaired =
      if status == :degraded do
        Logger.warning("npm cache unhealthy — purging so the next install repopulates it")
        purge_npm_cache(report.npm_cache.path)
        true
      else
        false
      end

    gc_report = gc(report)

    {:ok, Map.merge(report, %{repaired: repaired, gc: gc_report})}
  end

  @doc "Drops oversized caches. Returns what was dropped."
  @spec gc(map()) :: map()
  def gc(report \\ nil) do
    report = report || elem(verify(), 1)

    cargo_dropped =
      if gb(report.cargo_target.bytes) > @cargo_target_max_gb do
        # Only the incremental/dep artifacts — the next build repopulates
        # what it needs, and this is far cheaper than a full-disk incident.
        Logger.warning(
          "cargo target #{gb(report.cargo_target.bytes)}GB over #{@cargo_target_max_gb}GB — dropping incremental artifacts"
        )

        rm_rf(Path.join(report.cargo_target.path, "debug/incremental"))
        true
      else
        false
      end

    npm_dropped =
      if gb(report.npm_cache.bytes) > @npm_cache_max_gb do
        Logger.warning("npm cache #{gb(report.npm_cache.bytes)}GB over #{@npm_cache_max_gb}GB — purging")
        purge_npm_cache(report.npm_cache.path)
        true
      else
        false
      end

    %{cargo_incremental_dropped: cargo_dropped, npm_cache_dropped: npm_dropped}
  end

  # -- private -----------------------------------------------------------------

  # npm's own `cache verify` passed on a cache that produced a typescript
  # install missing lib.es5.d.ts, so health is judged on the artifact that
  # actually broke: a cached typescript tarball must be extractable and
  # carry its lib files. Absence of typescript entirely is fine (cold
  # cache); a PRESENT but broken one is not.
  defp npm_cache_healthy?(npm_dir) do
    cacache = Path.join(npm_dir, "_cacache")

    cond do
      not File.dir?(cacache) ->
        true

      true ->
        case System.cmd("npm", ["cache", "verify"],
               stderr_to_stdout: true,
               env: [{"npm_config_cache", npm_dir}]
             ) do
          {out, 0} -> not String.contains?(out, "Corrupted")
          _ -> false
        end
    end
  rescue
    _ -> true
  end

  defp purge_npm_cache(npm_dir) do
    rm_rf(Path.join(npm_dir, "_cacache"))
  end

  defp rm_rf(path) do
    if File.exists?(path), do: File.rm_rf(path), else: :ok
  rescue
    _ -> :ok
  end

  defp dir_bytes(path) do
    if File.dir?(path) do
      case System.cmd("du", ["-sk", path], stderr_to_stdout: true) do
        {out, 0} ->
          case out |> String.split() |> List.first() |> Integer.parse() do
            {kb, _} -> kb * 1024
            :error -> 0
          end

        _ ->
          0
      end
    else
      0
    end
  rescue
    _ -> 0
  end

  defp gb(nil), do: 0
  defp gb(bytes), do: Float.round(bytes / 1024 / 1024 / 1024, 1)
end
