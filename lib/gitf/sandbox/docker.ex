defmodule GiTF.Sandbox.Docker do
  @moduledoc """
  Docker sandbox adapter.

  Runs commands inside a transient Docker container.
  Suitable for macOS/Windows where Bubblewrap is not available.
  """
  @behaviour GiTF.Sandbox

  # Lightweight base image, can be configured
  @image "alpine:latest"

  def wrap_command(cmd, args, opts) do
    cwd = Keyword.get(opts, :cd, File.cwd!())

    # Mount the working directory into the container
    docker_args =
      [
        "run",
        # Remove container after exit
        "--rm",
        # Interactive (keep stdin open)
        "-i",
        "-v",
        "#{cwd}:/workspace",
        "-w",
        "/workspace",
        # Share network
        "--network",
        "host",
        @image,
        cmd
      ] ++ args

    {"docker", docker_args, opts}
  end

  def available? do
    System.find_executable("docker") != nil
  end

  def name, do: "docker"
end
