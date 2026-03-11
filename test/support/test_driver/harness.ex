defmodule GiTF.TestDriver.Harness do
  @moduledoc """
  Creates and manages isolated test environments for E2E scenarios.

  Each scenario gets its own temp Store directory, git repository,
  and gitf workspace. Patterns extracted from existing test suites
  (`queen_test.exs`, `bees_test.exs`).
  """

  alias GiTF.Store
  alias GiTF.TestDriver.MockClaude

  @tmp_dir System.tmp_dir!()

  @type env :: %{
          store_dir: String.t(),
          gitf_root: String.t(),
          repos: %{String.t() => String.t()},
          combs: %{String.t() => map()},
          mock_dir: String.t(),
          queen_pid: pid() | nil
        }

  @doc """
  Boots an isolated environment for a scenario.

  Creates temp directories for the Store, gitf workspace, and mock scripts.
  Restarts the Store GenServer pointing at the temp directory.

  Returns an env map for use with other harness functions.
  """
  @spec boot(keyword()) :: env()
  def boot(opts \\ []) do
    suffix = :erlang.unique_integer([:positive])
    store_dir = Path.join(@tmp_dir, "gitf_e2e_store_#{suffix}")
    gitf_root = Path.join(@tmp_dir, "gitf_e2e_ws_#{suffix}")
    mock_dir = Path.join(@tmp_dir, "gitf_e2e_mocks_#{suffix}")

    File.mkdir_p!(store_dir)
    File.mkdir_p!(Path.join([gitf_root, ".gitf", "major"]))
    File.write!(Path.join([gitf_root, ".gitf", "config.toml"]), "")
    File.write!(Path.join([gitf_root, ".gitf", "major", "QUEEN.md"]), "# Major\n")
    File.mkdir_p!(mock_dir)

    # Restart Store with isolated directory
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = Store.start_link(data_dir: store_dir)

    env = %{
      store_dir: store_dir,
      gitf_root: gitf_root,
      repos: %{},
      combs: %{},
      mock_dir: mock_dir,
      queen_pid: nil
    }

    if Keyword.get(opts, :major, false) do
      start_major(env)
    else
      env
    end
  end

  @doc """
  Tears down the environment: stops processes, removes temp directories.
  """
  @spec teardown(env()) :: :ok
  def teardown(env) do
    if env.major_pid && Process.alive?(env.major_pid) do
      GenServer.stop(env.major_pid, :normal)
    end
  catch
    :exit, _ -> :ok
  after
    File.rm_rf(env.store_dir)
    File.rm_rf(env.gitf_root)
    File.rm_rf(env.mock_dir)

    Enum.each(env.repos, fn {_name, path} -> File.rm_rf(path) end)

    :ok
  end

  @doc """
  Creates a test git repo and registers it as a comb.

  Returns the updated env with the comb entry.
  """
  @spec add_comb(env(), keyword()) :: {:ok, env(), map()}
  def add_comb(env, opts \\ []) do
    name = Keyword.get(opts, :name, "test-comb-#{:erlang.unique_integer([:positive])}")
    repo_path = create_temp_git_repo(name)

    {:ok, comb} = GiTF.Comb.add(repo_path, name: name)

    env = %{
      env
      | repos: Map.put(env.repos, name, repo_path),
        combs: Map.put(env.combs, name, comb)
    }

    {:ok, env, comb}
  end

  @doc """
  Creates a quest with jobs and returns them.

  ## Options

    * `:name` - quest name
    * `:goal` - quest goal
    * `:jobs` - list of job attr maps (each needs `:title`, gets `:comb_id` from opts or first comb)
    * `:comb_id` - default comb_id for jobs
    * `:dependencies` - list of `{job_index, depends_on_index}` tuples

  """
  @spec create_quest(env(), keyword()) :: {:ok, map(), [map()]}
  def create_quest(env, opts \\ []) do
    goal = Keyword.get(opts, :goal, "Test quest #{:erlang.unique_integer([:positive])}")
    name = Keyword.get(opts, :name, nil)
    comb_id = Keyword.get(opts, :comb_id) || first_comb_id(env)

    quest_attrs = %{goal: goal}
    quest_attrs = if name, do: Map.put(quest_attrs, :name, name), else: quest_attrs

    {:ok, quest} = GiTF.Quests.create(quest_attrs)

    job_specs = Keyword.get(opts, :jobs, [%{title: "Default test job"}])

    jobs =
      Enum.map(job_specs, fn job_attrs ->
        attrs = Map.merge(job_attrs, %{quest_id: quest.id, comb_id: comb_id})
        {:ok, job} = GiTF.Jobs.create(attrs)
        job
      end)

    # Set up dependencies
    deps = Keyword.get(opts, :dependencies, [])

    Enum.each(deps, fn {job_idx, dep_idx} ->
      job = Enum.at(jobs, job_idx)
      dep = Enum.at(jobs, dep_idx)
      {:ok, _} = GiTF.Jobs.add_dependency(job.id, dep.id)
    end)

    {:ok, quest, jobs}
  end

  @doc """
  Spawns a ghost with a mock Claude executable for a given job.

  ## Options

    * `:exit_code` - mock exit code (default: 0)
    * `:delay_ms` - mock delay (default: 100)
    * `:mock_opts` - additional MockClaude options
    * `:name` - ghost name

  """
  @spec spawn_mock_bee(env(), String.t(), String.t(), keyword()) :: {:ok, map()}
  def spawn_mock_bee(env, job_id, comb_id, opts \\ []) do
    exit_code = Keyword.get(opts, :exit_code, 0)
    delay_ms = Keyword.get(opts, :delay_ms, 100)
    mock_opts = Keyword.get(opts, :mock_opts, [])

    all_mock_opts =
      [exit_code: exit_code, delay_ms: delay_ms] ++ mock_opts

    {:ok, script_path} = MockClaude.write_script(env.mock_dir, all_mock_opts)

    spawn_opts =
      [claude_executable: script_path, prompt: "test prompt"] ++
        Keyword.take(opts, [:name])

    GiTF.Ghosts.spawn(job_id, comb_id, env.gitf_root, spawn_opts)
  end

  @doc """
  Starts the Major GenServer pointing at the test workspace.

  Returns the updated env with the queen_pid.
  """
  @spec start_major(env()) :: env()
  def start_major(env) do
    # Terminate Major from supervisor to prevent auto-restart conflicts
    try do
      Supervisor.terminate_child(GiTF.Supervisor, GiTF.Major)
      Supervisor.delete_child(GiTF.Supervisor, GiTF.Major)
    catch
      :exit, _ -> :ok
    end
    safe_stop(Process.whereis(GiTF.Major))
    Process.sleep(10)

    {:ok, pid} = GiTF.Major.start_link(gitf_root: env.gitf_root)
    GiTF.Major.start_session()
    %{env | queen_pid: pid}
  end

  @doc """
  Sends a waggle message directly to the Major process.
  """
  @spec send_waggle_to_major(map()) :: :ok
  def send_waggle_to_major(waggle) do
    case Process.whereis(GiTF.Major) do
      nil -> :ok
      pid -> send(pid, {:waggle_received, waggle})
    end

    :ok
  end

  # -- Private -----------------------------------------------------------------

  defp create_temp_git_repo(name) do
    path = Path.join(@tmp_dir, "gitf_e2e_repo_#{name}_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(path)

    System.cmd("git", ["init"], cd: path, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@gitf.local"], cd: path)
    System.cmd("git", ["config", "user.name", "Test"], cd: path)

    readme = Path.join(path, "README.md")
    File.write!(readme, "# #{name}\n")
    System.cmd("git", ["add", "."], cd: path, stderr_to_stdout: true)
    System.cmd("git", ["commit", "-m", "initial"], cd: path, stderr_to_stdout: true)

    {real_path, 0} =
      System.cmd("git", ["rev-parse", "--show-toplevel"],
        cd: path,
        stderr_to_stdout: true
      )

    String.trim(real_path)
  end

  defp first_comb_id(env) do
    case Map.values(env.combs) do
      [comb | _] -> comb.id
      [] -> raise "No combs added to harness. Call add_comb/2 first."
    end
  end

  defp safe_stop(nil), do: :ok

  defp safe_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
  rescue
    _ -> :ok
  end
end
