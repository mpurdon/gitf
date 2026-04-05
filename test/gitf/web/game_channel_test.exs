defmodule GiTF.Web.GameChannelTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  @endpoint GiTF.Web.Endpoint

  # Start the endpoint ONCE for all tests in this module.
  # Using setup_all ensures the endpoint process is linked to the long-lived
  # setup_all process rather than individual test processes, preventing it
  # from being killed between tests.
  setup_all do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    # Use the app's Archive (don't restart it)
    unless Process.whereis(GiTF.Archive) do
      tmp_dir = Path.join(System.tmp_dir!(), "game_test_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      {:ok, _} = GiTF.Archive.start_link(data_dir: tmp_dir)
    end

    # Ensure Web.Endpoint is running with server: false
    ensure_web_endpoint!()

    :ok
  end

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    # Ensure PubSubBridge is alive (needed for forwarding telemetry events)
    unless Process.whereis(GiTF.PubSubBridge) &&
             Process.alive?(Process.whereis(GiTF.PubSubBridge)) do
      try do
        Supervisor.terminate_child(GiTF.Interface.Supervisor, GiTF.PubSubBridge)
        Supervisor.delete_child(GiTF.Interface.Supervisor, GiTF.PubSubBridge)
      catch
        :exit, _ -> :ok
      end

      GiTF.Test.StoreHelper.safe_stop(GiTF.PubSubBridge)
      {:ok, _} = GiTF.PubSubBridge.start_link([])
    end

    # Ensure endpoint is still alive (it should be, since setup_all owns it)
    ensure_web_endpoint!()

    # Create dummy sector data
    sector_name = "game-test-sector-#{System.os_time(:nanosecond)}"
    repo_path = Path.join(System.tmp_dir!(), sector_name)
    GiTF.Test.StoreHelper.init_git_repo!(repo_path)

    sector =
      case GiTF.Sector.add(repo_path, name: sector_name) do
        {:ok, c} ->
          c

        {:error, :name_already_taken} ->
          case GiTF.Sector.list() do
            [first | _] -> first
            [] -> raise "No sectors available and could not create one"
          end
      end

    # Connect
    {:ok, socket} = connect(GiTF.Web.UserSocket, %{})
    {:ok, _, socket} = subscribe_and_join(socket, "game:control", %{})

    %{socket: socket, sector: sector}
  end

  test "receives initial world state on join", %{socket: _socket} do
    assert_push("world_state", %{missions: _, ghosts: _, sectors: _})
  end

  test "receives section events", %{socket: _socket} do
    # Emit a fake telemetry event
    GiTF.Telemetry.emit([:gitf, :ghost, :spawned], %{}, %{ghost_id: "test-ghost"})

    # Assert pushed to channel
    assert_push("gitf_event", %{type: "gitf.ghost.spawned", data: %{ghost_id: "test-ghost"}})
  end

  test "can spawn mission via command", %{socket: socket} do
    ref = push(socket, "spawn_quest", %{"goal" => "Build a game"})
    assert_reply(ref, :ok, %{mission_id: _})
  end

  # -- Helpers ----------------------------------------------------------------

  defp ensure_web_endpoint! do
    ets_ok? =
      try do
        GiTF.Web.Endpoint.config(:pubsub_server)
        true
      rescue
        ArgumentError -> false
      end

    endpoint_pid = Process.whereis(GiTF.Web.Endpoint)
    endpoint_alive? = endpoint_pid != nil and Process.alive?(endpoint_pid)

    if endpoint_alive? and ets_ok? do
      :ok
    else
      # Terminate from supervisor to avoid conflicts
      try do
        Supervisor.terminate_child(GiTF.Interface.Supervisor, GiTF.Web.Endpoint)
      catch
        :exit, _ -> :ok
      end

      try do
        Supervisor.delete_child(GiTF.Interface.Supervisor, GiTF.Web.Endpoint)
      catch
        :exit, _ -> :ok
      end

      GiTF.Test.StoreHelper.safe_stop(GiTF.Web.Endpoint)
      Process.sleep(100)

      # Ensure config has server: false (no HTTP listener in tests)
      current = Application.get_env(:gitf, GiTF.Web.Endpoint, [])
      Application.put_env(:gitf, GiTF.Web.Endpoint, Keyword.put(current, :server, false))

      case GiTF.Web.Endpoint.start_link([]) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        other -> raise "Failed to start Web.Endpoint: #{inspect(other)}"
      end

      Process.sleep(50)
    end
  end
end
