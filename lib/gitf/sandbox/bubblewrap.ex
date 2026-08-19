defmodule GiTF.Sandbox.Bubblewrap do
  @moduledoc """
  Bubblewrap (bwrap) sandbox adapter.

  Wraps commands in a lightweight container using Linux namespaces.
  Requires 'bwrap' to be installed and accessible in PATH.
  """
  @behaviour GiTF.Sandbox

  def wrap_command(cmd, args, opts) do
    cwd = Keyword.get(opts, :cd, File.cwd!())
    risk_level = Keyword.get(opts, :risk_level, :low)

    bwrap_args =
      base_args() ++
        home_bind_args() ++
        cwd_bind_args(cwd, risk_level) ++
        [
          "--die-with-parent",
          "--new-session",
          "--",
          cmd
        ] ++ args

    {"bwrap", bwrap_args, opts}
  end

  # AI CLIs (claude/node/git, incl. nvm-installed runtimes) need to read the
  # user home to run, and write a few config/cache dirs. Bind home read-only
  # for resolution, then rebind the writable config dirs. Destructive writes
  # stay confined to these + the worktree + tmpfs /tmp.
  defp home_bind_args do
    case System.user_home() do
      nil ->
        []

      home ->
        # Download caches are shared for speed but must be UNCORRUPTIBLE:
        # OOM-killed ghosts writing ~/.npm/_cacache left npm exiting 0 with a
        # broken typescript install, which cost runs 21, 27 and 30. Bound as
        # overlays — the warm shared copy is the read-only lower layer, each
        # sandbox writes to its own throwaway upper layer. Cache misses still
        # install; the shared copy simply cannot be damaged by a dying ghost.
        overlay =
          if tmp_overlay_supported?() do
            for sub <- [".npm", ".cargo"],
                path = Path.join(home, sub),
                File.dir?(path),
                arg <- ["--overlay-src", path, "--tmp-overlay", path],
                do: arg
          else
            []
          end

        overlaid = if overlay == [], do: [], else: [".npm", ".cargo"]

        # cargo-target is a BUILD OUTPUT, not a download cache: cargo must
        # write it, guards it with its own lock, and an overlay would throw
        # away exactly the incremental artifacts that make a probe build 90
        # seconds instead of 25 minutes.
        writable =
          for sub <- [".claude", ".config", ".cache", ".npm", ".cargo", "cargo-target"],
              sub not in overlaid,
              path = Path.join(home, sub),
              File.dir?(path),
              arg <- ["--bind", path, path],
              do: arg

        ["--ro-bind", home, home] ++ writable ++ overlay
    end
  end

  # bwrap gained --tmp-overlay in 0.9.0 and it needs unprivileged overlayfs
  # in user namespaces. Probe once per boot; fall back to a plain writable
  # bind (today's behaviour) rather than failing closed on older hosts.
  @overlay_cache_key {__MODULE__, :tmp_overlay}
  defp tmp_overlay_supported? do
    case :persistent_term.get(@overlay_cache_key, nil) do
      nil ->
        supported =
          case System.cmd("bwrap", ["--help"], stderr_to_stdout: true) do
            {out, _} -> String.contains?(out, "--tmp-overlay")
          end

        :persistent_term.put(@overlay_cache_key, supported)
        supported

      cached ->
        cached
    end
  rescue
    _ -> false
  end

  # Only bind paths that exist on THIS host: /lib64 does not exist on arm64
  # Ubuntu, and a bwrap --ro-bind of a missing source dies with "Can't find
  # source path" before the sandboxed command ever runs. That single
  # hardcoded bind kept the sandbox broken on the arm64 box even after the
  # AppArmor userns fix — with sandbox_required set, every AI shell command
  # was (correctly) refused and ghosts flew blind (msn-9695ad, finding #16).
  # /etc is bound selectively — /etc/gitf holds secrets that AI-authored
  # commands must never read. /etc/alternatives is required or every
  # Debian-alternatives symlink dangles inside the sandbox (run 27: rustc
  # died with "linker `cc` not found" because /usr/bin/cc points through
  # it); the ld.so entries keep the dynamic linker's view consistent.
  @candidate_ro_binds [
    "/usr",
    "/bin",
    "/lib",
    "/lib64",
    "/etc/resolv.conf",
    "/etc/ssl/certs",
    "/etc/alternatives",
    "/etc/ld.so.cache",
    "/etc/ld.so.conf",
    "/etc/ld.so.conf.d"
  ]

  defp base_args do
    ro_binds =
      for path <- @candidate_ro_binds,
          File.exists?(path),
          arg <- ["--ro-bind", path, path],
          do: arg

    [
      "--unshare-all",
      "--share-net",
      "--dev",
      "/dev",
      "--proc",
      "/proc",
      "--tmpfs",
      "/tmp"
    ] ++ ro_binds
  end

  # Critical risk: read-only worktree
  defp cwd_bind_args(cwd, :critical), do: ["--ro-bind", cwd, cwd]
  # All other risk levels: read-write worktree
  defp cwd_bind_args(cwd, _risk_level), do: ["--bind", cwd, cwd]

  @probe_cache_key {__MODULE__, :probe}
  @probe_ttl_ms 60_000
  @probe_timeout_ms 5_000

  @doc """
  A binary on PATH is not a working sandbox: host policy (Ubuntu's AppArmor
  `unprivileged_userns` restriction, seccomp, kernel sysctls) can let bwrap
  exist yet fail at namespace setup. When that happened, every validation
  died at "bwrap: setting up uid map: Permission denied" and the failures
  were attributed to the ghost's code. So availability means "a trivial
  command actually ran inside the production flag set" — probed for real,
  cached #{div(@probe_ttl_ms, 1000)}s, with a critical alert on breakage.
  """
  def available? do
    System.find_executable("bwrap") != nil and probe_ok?()
  end

  def name, do: "bubblewrap"

  defp probe_ok? do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@probe_cache_key, nil) do
      {result, at} when now - at < @probe_ttl_ms ->
        result

      previous ->
        result = run_probe()
        :persistent_term.put(@probe_cache_key, {result, now})
        maybe_alert(previous, result)
        result
    end
  end

  defp run_probe do
    task =
      Task.async(fn ->
        try do
          System.cmd(
            "bwrap",
            base_args() ++ ["--die-with-parent", "--", "true"],
            stderr_to_stdout: true
          )
        rescue
          e -> {:probe_exception, Exception.message(e)}
        end
      end)

    case Task.yield(task, @probe_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_out, 0}} ->
        {:ok, nil}

      {:ok, {out, code}} when is_binary(out) ->
        {:broken, "exit #{code}: #{String.slice(out, 0, 200)}"}

      {:ok, {:probe_exception, msg}} ->
        {:broken, msg}

      _ ->
        {:broken, "probe timed out after #{@probe_timeout_ms}ms"}
    end
    |> case do
      {:ok, _} -> true
      {:broken, reason} -> put_last_error(reason)
    end
  end

  defp put_last_error(reason) do
    :persistent_term.put({__MODULE__, :last_error}, reason)
    false
  end

  @doc "Why the last probe failed, if it did."
  def last_error, do: :persistent_term.get({__MODULE__, :last_error}, nil)

  # Alert on healthy→broken transitions (and the very first broken probe),
  # not on every cached re-check — the webhook dedup key keeps repeats quiet.
  defp maybe_alert({false, _at}, false), do: :ok

  defp maybe_alert(_previous, false) do
    require Logger
    reason = last_error() || "unknown"

    Logger.error(
      "bwrap sandbox BROKEN on this host: #{reason} — AI-authored commands " <>
        "cannot be sandboxed; validations must not attribute this to the code under test"
    )

    GiTF.Observability.Alerts.dispatch_webhook(
      :sandbox_broken,
      "bwrap present but cannot create sandboxes (#{reason}). If this host runs " <>
        "Ubuntu's AppArmor userns restriction, install the bwrap userns profile " <>
        "(rel/install-systemd.sh does this).",
      dedup_key: "sandbox_broken:#{node()}"
    )
  rescue
    # Alerting must never take down the availability check.
    _ -> :ok
  end

  defp maybe_alert(_previous, true), do: :ok
end
