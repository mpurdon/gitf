defmodule GiTF.InstallCache do
  @moduledoc """
  A `node_modules` the factory only pays for once per lockfile.

  Every validation command on cora begins `npm ci`. On the box (2 vCPU,
  3.8 GB) that is four to five minutes of extraction for a tree that is
  byte-identical to the one the previous ghost extracted, and it runs
  once per implementation worktree, once per fix worktree, and once per
  per-op quality gate — under the sector lock, so everything else waits.
  msn-5f2be2 changed sixteen lines of CSS and spent 5m29s installing
  before validation and another 5m14s while a simplify op's gate
  installed again, with publish blocked behind it.

  The cache is keyed by the SHA-256 of the lockfile. `restore/1` runs
  right before a validation command: if the worktree has a lockfile, no
  `node_modules`, and the cache holds that key, the cached tree is
  HARDLINKED into place (`cp -al` — same volume, seconds, no extra disk)
  and the command is told so through its environment:

      GITF_INSTALL_KEY=<sha256>      always, when a lockfile exists
      GITF_INSTALL_RESTORED=1|0      whether node_modules came from cache

  `store/1` runs after a validation command SUCCEEDS: a real
  `node_modules` under a key the cache lacks is hardlinked into the
  cache. The command's own `npm ci` is what populates it the first time.

  ## The contract with the sector's validation command

  The factory cannot make `npm ci` skip itself — `npm ci` deletes
  `node_modules` unconditionally. So a sector that wants the cache says
  so in its command:

      { [ "$GITF_INSTALL_RESTORED" = 1 ] && [ -f node_modules/.package-lock.json ]; } \\
        || npm ci
      npm run typecheck && ...

  A command that ignores the variables behaves exactly as before.

  ## Why hardlinks are safe enough

  `npm ci` removes a tree by unlinking — the cache's inodes survive. npm
  writes files by creating new ones and renaming, never in place. What
  would corrupt the cache is a ghost hand-editing a file inside
  `node_modules`, which is both rare and a thing the ghost should not be
  doing. `cp -al` falls back to `cp -a` if the cache and the worktree
  ever end up on different volumes.

  ## Retention

  One key is one lockfile version, roughly 200 MB of hardlinked inodes
  (the space is shared with any live worktree that holds it). `prune/1`
  keeps the `keep` most recently restored keys — default 3 — and runs
  from Tachikoma's sweep beside `GiTF.Inquiry.Preview.prune/0`.
  """

  require Logger

  @lockfiles ["package-lock.json", "npm-shrinkwrap.json"]
  @marker ".gitf-install-key"
  @default_keep 3

  @type restore_result ::
          {:restored, String.t()} | {:present, String.t()} | {:miss, String.t()} | :not_applicable

  @doc "Whether the cache is on (`[:install_cache, :enabled]`, default true)."
  @spec enabled?() :: boolean()
  def enabled?, do: GiTF.Config.Provider.get([:install_cache, :enabled], true) != false

  @doc "The cache directory: `<gitf root>/.gitf/cache/node_modules`, or the test override."
  @spec root() :: {:ok, Path.t()} | {:error, term()}
  def root do
    with nil <- Application.get_env(:gitf, :install_cache_root),
         {:ok, gitf_root} <- GiTF.gitf_dir() do
      {:ok, Path.join([gitf_root, ".gitf", "cache", "node_modules"])}
    else
      path when is_binary(path) -> {:ok, Path.expand(path)}
      err -> err
    end
  end

  @doc "The cache key for `worktree`: SHA-256 of its lockfile, or nil without one."
  @spec key(Path.t()) :: String.t() | nil
  def key(worktree) do
    with path when is_binary(path) <- lockfile(worktree),
         {:ok, bytes} <- File.read(path) do
      GiTF.Vault.File.content_hash(bytes)
    else
      _ -> nil
    end
  end

  @doc """
  Puts a cached `node_modules` into `worktree` if one exists for its
  lockfile and the worktree has none. Never raises; a cache failure is a
  slow install, not a failed validation.
  """
  @spec restore(Path.t()) :: restore_result()
  def restore(worktree) do
    with true <- enabled?(),
         key when is_binary(key) <- key(worktree),
         {:ok, root} <- root() do
      target = Path.join(worktree, "node_modules")
      cached = cached_tree(root, key)

      cond do
        File.dir?(target) ->
          if marker(target) == key, do: {:restored, key}, else: {:present, key}

        File.dir?(cached) ->
          case link_tree(cached, target) do
            :ok ->
              File.write(Path.join(target, @marker), key)
              File.touch(Path.dirname(cached))
              Logger.info("InstallCache: restored node_modules #{short(key)} into #{worktree}")
              {:restored, key}

            {:error, reason} ->
              Logger.warning("InstallCache: restore of #{short(key)} failed: #{inspect(reason)}")
              File.rm_rf(target)
              {:miss, key}
          end

        true ->
          {:miss, key}
      end
    else
      _ -> :not_applicable
    end
  rescue
    e ->
      Logger.warning("InstallCache: restore crashed: #{Exception.message(e)}")
      :not_applicable
  end

  @doc """
  Copies `worktree`'s `node_modules` into the cache under the lockfile's
  key when the cache lacks it. Call after a validation command SUCCEEDED
  — a failed install must not be enshrined.
  """
  @spec store(Path.t(), restore_result() | nil) ::
          :stored | :exists | :not_applicable | {:error, term()}
  def store(worktree, install \\ nil)

  # Restored from the cache means it is already in the cache.
  def store(_worktree, {:restored, _key}), do: :exists

  def store(worktree, install) do
    with true <- enabled?(),
         key when is_binary(key) <- known_key(install) || key(worktree),
         {:ok, root} <- root(),
         source = Path.join(worktree, "node_modules"),
         true <- File.dir?(source) do
      cached = cached_tree(root, key)

      if File.dir?(cached) do
        :exists
      else
        staging = Path.join(root, "#{key}.tmp-#{System.unique_integer([:positive])}")

        with :ok <- File.mkdir_p(staging),
             :ok <- link_tree(source, Path.join(staging, "node_modules")),
             :ok <- File.write(Path.join([staging, "node_modules", @marker]), key),
             :ok <- File.rename(staging, Path.join(root, key)) do
          File.write(Path.join(source, @marker), key)
          Logger.info("InstallCache: stored node_modules #{short(key)} from #{worktree}")
          :stored
        else
          {:error, reason} = err ->
            File.rm_rf(staging)
            Logger.warning("InstallCache: store of #{short(key)} failed: #{inspect(reason)}")
            err
        end
      end
    else
      _ -> :not_applicable
    end
  rescue
    e ->
      Logger.warning("InstallCache: store crashed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc "Environment for the validation command, from a `restore/1` result."
  @spec env(restore_result()) :: [{String.t(), String.t()}]
  def env({state, key}) when state in [:restored, :present, :miss] do
    restored = if state == :restored, do: "1", else: "0"
    [{"GITF_INSTALL_KEY", key}, {"GITF_INSTALL_RESTORED", restored}]
  end

  def env(_), do: []

  @doc """
  Removes every cached key beyond the `keep` most recently restored.
  Returns `%{removed: n, kept: m}`.
  """
  @spec prune(pos_integer()) :: %{removed: non_neg_integer(), kept: non_neg_integer()}
  def prune(keep \\ @default_keep) do
    with {:ok, root} <- root(), true <- File.dir?(root) do
      # Only real keys: a `.tmp-*` is a store in progress and a `.rm-*` is
      # a tree already condemned and being unlinked in the background.
      entries =
        root
        |> File.ls!()
        |> Enum.reject(&(String.contains?(&1, ".tmp-") or String.contains?(&1, ".rm-")))
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.sort_by(&mtime/1, :desc)

      {kept, doomed} = Enum.split(entries, keep)
      Enum.each(doomed, &remove_tree_async/1)
      %{removed: length(doomed), kept: length(kept)}
    else
      _ -> %{removed: 0, kept: 0}
    end
  rescue
    _ -> %{removed: 0, kept: 0}
  end

  # -- internals ---------------------------------------------------------------

  # A cached tree is tens of thousands of files. Renaming it out of the
  # way is instant and hides it from `restore/1`; the unlinking happens
  # off the caller (Tachikoma's sweep runs in its GenServer) and in
  # coreutils, not a BEAM directory walk.
  defp remove_tree_async(dir) do
    doomed = "#{dir}.rm-#{System.unique_integer([:positive])}"

    case File.rename(dir, doomed) do
      :ok ->
        Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
          System.cmd("rm", ["-rf", doomed])
        end)

      {:error, _} ->
        File.rm_rf(dir)
    end
  end

  defp known_key({_state, key}) when is_binary(key), do: key
  defp known_key(_), do: nil

  defp lockfile(worktree) do
    Enum.find_value(@lockfiles, fn name ->
      path = Path.join(worktree, name)
      if File.regular?(path), do: path
    end)
  end

  defp cached_tree(root, key), do: Path.join([root, key, "node_modules"])

  defp marker(node_modules) do
    case File.read(Path.join(node_modules, @marker)) do
      {:ok, key} -> String.trim(key)
      _ -> nil
    end
  end

  # Hardlink copy; falls back to a real copy across devices. `cp` rather
  # than File.cp_r because a node_modules is tens of thousands of files
  # and the coreutils walk is an order of magnitude faster than Elixir's.
  defp link_tree(source, target) do
    File.mkdir_p!(Path.dirname(target))

    with {out, code} when code != 0 <- cp(["-al", source, target]),
         _ <- File.rm_rf(target),
         {out2, code2} when code2 != 0 <- cp(["-a", source, target]) do
      {:error, {:cp, code2, String.slice(out <> out2, 0, 300)}}
    else
      _ -> :ok
    end
  end

  defp cp(args), do: System.cmd("cp", args, stderr_to_stdout: true)

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: t}} -> t
      _ -> 0
    end
  end

  defp short(key), do: String.slice(key, 0, 12)
end
