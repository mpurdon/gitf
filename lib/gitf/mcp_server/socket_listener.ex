defmodule GiTF.MCPServer.SocketListener do
  @moduledoc """
  Listens for MCP connections on a Unix domain socket.

  The daemon starts this listener as part of the supervision tree.
  Each incoming connection is handled by a spawned process that reads
  newline-delimited JSON-RPC messages and dispatches them to the
  existing `GiTF.MCPServer` message handler.

  Socket path: `~/.config/gitf/mcp.sock` (configurable via `GITF_MCP_SOCK`)

  A PID file (`<socket_path>.pid`) is written on startup and checked
  to detect stale sockets from crashed previous instances.
  """

  use GenServer
  require Logger

  @default_socket_dir Path.join([System.user_home!(), ".config", "gitf"])

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc "Returns the socket path."
  def socket_path do
    System.get_env("GITF_MCP_SOCK") || Path.join(@default_socket_dir, "mcp.sock")
  end

  @doc "Returns the PID file path for the socket."
  def pid_path, do: socket_path() <> ".pid"

  @doc "Cleans up the socket and PID file. Called from Application.prep_stop/1."
  def cleanup do
    File.rm(socket_path())
    File.rm(pid_path())
    :ok
  end

  @impl true
  def init(_opts) do
    path = socket_path()

    # Ensure directory exists
    File.mkdir_p!(Path.dirname(path))

    case cleanup_stale_socket(path) do
      :ok ->
        case :gen_tcp.listen(0, [
               {:ifaddr, {:local, path}},
               :binary,
               packet: :line,
               active: false,
               reuseaddr: true,
               recbuf: 65_536,
               sndbuf: 1_048_576
             ]) do
          {:ok, listen_socket} ->
            write_pid_file()
            Logger.info("MCP socket listening at #{path}")
            send(self(), :accept)
            {:ok, %{listen_socket: listen_socket, path: path}}

          {:error, reason} ->
            Logger.error("Failed to start MCP socket at #{path}: #{inspect(reason)}")
            {:stop, reason}
        end

      {:error, :already_running} ->
        Logger.error("Another GiTF instance is already running (PID file: #{pid_path()})")
        {:stop, :already_running}
    end
  end

  @impl true
  def handle_info(:accept, state) do
    parent = self()

    Task.start(fn ->
      case :gen_tcp.accept(state.listen_socket) do
        {:ok, client_socket} ->
          Logger.info("MCP client connected via socket")
          send(parent, :accept)
          handle_connection(client_socket)

        {:error, :closed} ->
          Logger.info("MCP socket closed")

        {:error, reason} ->
          Logger.warning("MCP socket accept error: #{inspect(reason)}")
          send(parent, :accept)
      end
    end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen_socket)
    File.rm(state.path)
    File.rm(pid_path())
    :ok
  rescue
    _ -> :ok
  end

  # -- PID file management -----------------------------------------------------

  defp cleanup_stale_socket(path) do
    pid_file = pid_path()

    case File.read(pid_file) do
      {:ok, content} ->
        old_pid = String.trim(content)

        if process_alive?(old_pid) do
          {:error, :already_running}
        else
          # Stale socket from a crashed process — clean up
          Logger.info("Removing stale MCP socket (old PID #{old_pid} is dead)")
          File.rm(path)
          File.rm(pid_file)
          :ok
        end

      {:error, :enoent} ->
        # No PID file — remove socket if it exists (leftover from before PID files)
        File.rm(path)
        :ok
    end
  end

  defp process_alive?(pid_str) do
    case System.cmd("kill", ["-0", pid_str], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp write_pid_file do
    File.write!(pid_path(), to_string(:os.getpid()))
  end

  # -- Connection handler ------------------------------------------------------

  defp handle_connection(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        line = String.trim(data)

        if line != "" do
          case Jason.decode(line) do
            {:ok, message} ->
              response = GiTF.MCPServer.handle_rpc(message)

              if response do
                :gen_tcp.send(socket, Jason.encode!(response) <> "\n")
              end

            {:error, _} ->
              Logger.debug("MCP socket: invalid JSON: #{String.slice(line, 0, 100)}")
          end
        end

        handle_connection(socket)

      {:error, :closed} ->
        Logger.info("MCP client disconnected")
        :ok

      {:error, reason} ->
        Logger.warning("MCP socket recv error: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.warning("MCP socket handler crashed: #{Exception.message(e)}")
      :ok
  end
end
