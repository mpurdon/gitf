defmodule GiTF.Test.StoreHelper do
  @moduledoc """
  Helpers for restarting GenServers in tests.

  The application starts GiTF.Archive, GiTF.Major, GiTF.Tachikoma, etc. automatically.
  Tests that need isolated instances must stop the existing ones first.
  """

  @doc """
  Stops any running GiTF.Archive and starts a fresh one with the given data_dir.
  Returns `{:ok, pid}`.
  """
  def restart_store!(data_dir) do
    stop_store()
    GiTF.Archive.start_link(data_dir: data_dir)
  end

  @doc "Stops the currently running GiTF.Archive, if any."
  def stop_store do
    # First try to terminate and remove from the supervisor to prevent auto-restart
    try do
      Supervisor.terminate_child(GiTF.Supervisor, GiTF.Archive)
      Supervisor.delete_child(GiTF.Supervisor, GiTF.Archive)
    catch
      :exit, _ -> :ok
    end

    # Also try direct stop in case it was started outside the supervisor
    safe_stop(GiTF.Archive)

    # Brief pause to ensure the process is fully down
    Process.sleep(10)

    # A stopped Archive's ETS tables live on (heir-preserved, or still owned
    # by a lingering test process), and the next Archive's init only sweeps
    # tables its registry knows about — records from this store would leak
    # into the next test's "fresh" one. Purge everything.
    GiTF.Archive.purge_all_tables()

    # Keyless test envs route real LLM failures into the provider circuit;
    # a breaker left open by one test makes a later test's provider
    # preflight report :all_providers_down. Close them all.
    GiTF.Runtime.ProviderCircuit.reset_all()
  end

  @doc """
  Starts a fresh, healthy GiTF.Archive for tests that use the app-level
  singleton rather than an isolated store (most simulator / skills / E2E
  tests). Call this from the `on_exit` of any helper that ran `stop_store/0`
  — otherwise a later non-isolated test finds *no* Archive (or a half-torn-down
  one) and its setup blows up, which is the dominant source of order-dependent
  failures in the suite.

  Uses a stable temp directory so repeated restores don't leak dirs; the
  contents don't matter because non-isolated tests sweep the collections they
  care about in their own `setup`.
  """
  def restore_app_store do
    stop_store()
    # stop_store/0 swallows a GenServer.stop timeout, so a wedged Archive may
    # still be registered — kill it hard before we try to take its name.
    case Process.whereis(GiTF.Archive) do
      nil -> :ok
      pid -> Process.exit(pid, :kill); Process.sleep(20)
    end

    dir = Path.join(System.tmp_dir!(), "gitf_test_app_store")
    File.mkdir_p!(dir)

    case GiTF.Archive.start_link(data_dir: dir) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, pid}} ->
        Process.exit(pid, :kill)
        Process.sleep(20)
        {:ok, _pid} = GiTF.Archive.start_link(data_dir: dir)
        :ok
    end
  end

  @doc "Stops a named GenServer if it's running. Catches exits gracefully."
  def safe_stop(name) when is_atom(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> safe_stop_pid(pid)
    end
  end

  def safe_stop(pid) when is_pid(pid) do
    safe_stop_pid(pid)
  end

  @doc "Initializes a basic git repository with an initial commit for tests"
  def init_git_repo!(path) do
    File.mkdir_p!(path)
    # -b main: don't inherit the host's init.defaultBranch
    System.cmd("/usr/bin/git", ["init", "-b", "main"], cd: path)
    System.cmd("/usr/bin/git", ["config", "user.email", "test@example.com"], cd: path)
    System.cmd("/usr/bin/git", ["config", "user.name", "Test User"], cd: path)
    File.write!(Path.join(path, "README.md"), "# Test Repo")
    System.cmd("/usr/bin/git", ["add", "README.md"], cd: path)
    System.cmd("/usr/bin/git", ["commit", "-m", "Initial commit"], cd: path)
    :ok
  end

  @doc """
  Ensures essential infrastructure (PubSub, Registry) is running.
  Call this in test setup if tests may have crashed these processes.
  """
  def ensure_infrastructure do
    # Ensure PubSub is running and functional
    pubsub_ok? =
      case Process.whereis(GiTF.PubSub) do
        nil -> false
        pid -> Process.alive?(pid)
      end

    if !pubsub_ok? do
      Phoenix.PubSub.Supervisor.start_link(name: GiTF.PubSub)
    end

    # Ensure Registry is running and functional
    registry_ok? =
      try do
        Registry.lookup(GiTF.Registry, :__health_check__)
        true
      rescue
        ArgumentError -> false
      end

    if !registry_ok? do
      # Kill any zombie process
      case Process.whereis(GiTF.Registry) do
        nil ->
          :ok

        pid ->
          try do
            GenServer.stop(pid, :normal, 1000)
          catch
            :exit, _ -> :ok
          end
      end

      Process.sleep(10)
      Registry.start_link(keys: :unique, name: GiTF.Registry)
    end

    :ok
  end

  defp safe_stop_pid(pid) do
    try do
      GenServer.stop(pid, :normal, 5000)
    catch
      :exit, _ -> :ok
    end
  end
end
