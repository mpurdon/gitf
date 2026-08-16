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
        writable =
          for sub <- [".claude", ".config", ".cache", ".npm"],
              path = Path.join(home, sub),
              File.dir?(path),
              arg <- ["--bind", path, path],
              do: arg

        ["--ro-bind", home, home] ++ writable
    end
  end

  defp base_args do
    [
      "--unshare-all",
      "--share-net",
      "--dev",
      "/dev",
      "--proc",
      "/proc",
      "--tmpfs",
      "/tmp",
      "--ro-bind",
      "/usr",
      "/usr",
      "--ro-bind",
      "/bin",
      "/bin",
      "--ro-bind",
      "/lib",
      "/lib",
      "--ro-bind",
      "/lib64",
      "/lib64",
      "--ro-bind",
      "/etc/resolv.conf",
      "/etc/resolv.conf",
      "--ro-bind",
      "/etc/ssl/certs",
      "/etc/ssl/certs"
    ]
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
