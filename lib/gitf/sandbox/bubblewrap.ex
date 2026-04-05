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
        cwd_bind_args(cwd, risk_level) ++
        [
          "--die-with-parent",
          "--new-session",
          "--",
          cmd
        ] ++ args

    {"bwrap", bwrap_args, opts}
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

  def available? do
    System.find_executable("bwrap") != nil
  end

  def name, do: "bubblewrap"
end
