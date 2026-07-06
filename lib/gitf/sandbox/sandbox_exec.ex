defmodule GiTF.Sandbox.SandboxExec do
  @moduledoc """
  macOS sandbox-exec adapter.

  Wraps commands using the built-in macOS `sandbox-exec` tool with
  dynamically generated SBPL (Seatbelt Profile Language) profiles.
  Provides kernel-level sandboxing on macOS similar to Bubblewrap on Linux.
  """
  @behaviour GiTF.Sandbox

  def wrap_command(cmd, args, opts) do
    cwd = Keyword.get(opts, :cd, File.cwd!())
    risk_level = Keyword.get(opts, :risk_level, :low)

    profile = build_profile(cwd, risk_level)

    {"sandbox-exec", ["-p", profile, cmd | args], opts}
  end

  def available? do
    match?({:unix, :darwin}, :os.type())
  end

  def name, do: "sandbox-exec"

  defp build_profile(cwd, risk_level) do
    escaped_cwd = escape_sbpl(cwd)

    """
    (version 1)
    (deny default)
    (allow process*)
    (allow network*)
    (allow sysctl-read)
    (allow mach-lookup)
    (allow ipc-posix-shm-read-data)
    (allow file-read* (literal "/"))
    (allow file-read* (subpath "/usr"))
    (allow file-read* (subpath "/bin"))
    (allow file-read* (subpath "/sbin"))
    (allow file-read* (subpath "/System"))
    (allow file-read* (subpath "/Library"))
    (allow file-read* (subpath "/etc"))
    (allow file-read* (subpath "/var"))
    (allow file-read* (subpath "/dev"))
    (allow file-read* (subpath "/opt/homebrew"))
    (allow file-read* (subpath "/usr/local"))
    (allow file-read* (subpath "/private"))
    (allow file-read* file-write* (subpath "/tmp"))
    (allow file-read* file-write* (subpath "/private/tmp"))
    (allow file-read* file-write* (subpath "/var/tmp"))
    #{home_rules()}
    #{cwd_rule(escaped_cwd, risk_level)}\
    """
    |> String.trim()
  end

  # AI CLIs (claude/node/git) need to READ the user home (config, node
  # runtime, ~/.gitconfig, nvm) to function, and WRITE a small set of config
  # dirs (session state, caches). Broad read is acceptable — network is
  # allowed regardless, so read-restriction wouldn't prevent exfil; the real
  # threat is destructive writes, which stay confined to these dirs + the
  # worktree + tmp.
  defp home_rules do
    case System.user_home() do
      nil ->
        ""

      home ->
        h = escape_sbpl(home)

        [
          ~s[(allow file-read* (subpath "#{h}"))],
          ~s[(allow file-read* file-write* (subpath "#{h}/.claude"))],
          ~s[(allow file-read* file-write* (subpath "#{h}/.config"))],
          ~s[(allow file-read* file-write* (subpath "#{h}/.cache"))],
          ~s[(allow file-read* file-write* (subpath "#{h}/.npm"))]
        ]
        |> Enum.join("\n    ")
    end
  end

  defp cwd_rule(escaped_cwd, :critical) do
    ~s[(allow file-read* (subpath "#{escaped_cwd}"))]
  end

  defp cwd_rule(escaped_cwd, _risk_level) do
    ~s[(allow file-read* file-write* (subpath "#{escaped_cwd}"))]
  end

  defp escape_sbpl(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end
end
