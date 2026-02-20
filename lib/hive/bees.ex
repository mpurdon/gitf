defmodule Hive.Bees do
  @moduledoc """
  Context module for managing bee agents.

  Provides the public API for spawning, listing, and stopping bees. This
  module coordinates between the Bee.Worker GenServer (runtime lifecycle),
  the Store (persistence), and the CombSupervisor (process supervision).

  This is a context module: thin orchestration layer over store records
  and supervised processes.
  """

  alias Hive.Store

  # -- Public API --------------------------------------------------------------

  @doc """
  Spawns a new bee to work on a job.

  1. Creates a bee record in the store
  2. Assigns the job to the bee
  3. Starts a Bee.Worker under CombSupervisor

  ## Options

    * `:name` - human-friendly name (default: auto-generated)
    * `:prompt` - explicit prompt (overrides job description)
    * `:claude_executable` - path to executable (for testing)

  Returns `{:ok, bee}` or `{:error, reason}`.
  """
  @spec spawn(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def spawn(job_id, comb_id, hive_root, opts \\ []) do
    name = Keyword.get(opts, :name, generate_bee_name())

    with :ok <- check_job_ready(job_id),
         {:ok, bee} <- create_bee_record(name, job_id),
         :ok <- assign_job(job_id, bee.id),
         {:ok, _pid} <- start_worker(bee.id, job_id, comb_id, hive_root, opts) do
      {:ok, bee}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Spawns a bee as a detached OS process (for CLI use).

  Unlike `spawn/4`, this does NOT start a Worker GenServer. Instead it:
  1. Creates a bee record and assigns the job
  2. Creates a cell (git worktree) directly
  3. Updates bee status to "working"
  4. Generates settings for the bee
  5. Spawns Claude as a detached OS process via a wrapper script

  The wrapper script runs Claude headless, then calls `hive` CLI to
  update the bee/job status when Claude exits. This avoids keeping
  the escript alive (which would block the store file).

  Returns `{:ok, bee}` or `{:error, reason}`.
  """
  @spec spawn_detached(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def spawn_detached(job_id, comb_id, hive_root, opts \\ []) do
    name = Keyword.get(opts, :name, generate_bee_name())

    with :ok <- check_job_ready(job_id),
         {:ok, bee} <- create_bee_record(name, job_id),
         :ok <- assign_job(job_id, bee.id),
         {:ok, cell} <- Hive.Cell.create(comb_id, bee.id, hive_root: hive_root),
         :ok <- update_bee_working(bee.id, cell),
         :ok <- maybe_transition_job(job_id),
         :ok <- maybe_ensure_agent(job_id, comb_id, cell),
         {:ok, _os_pid} <- spawn_model_detached(bee.id, job_id, cell, hive_root) do
      {:ok, bee}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Revives a dead bee by spawning a new bee into its existing worktree.

  The dead bee must be "stopped" or "crashed". Its cell and worktree are
  reassigned to the new bee, which receives a prompt instructing it to
  finalize the existing work rather than starting over.

  Returns `{:ok, new_bee}` or `{:error, reason}`.
  """
  @spec revive(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def revive(dead_bee_id, hive_root, opts \\ []) do
    with {:ok, dead_bee} <- get(dead_bee_id),
         :ok <- validate_dead(dead_bee),
         {:ok, cell} <- find_active_cell(dead_bee_id),
         :ok <- validate_worktree_exists(cell),
         {:ok, job} <- Hive.Jobs.get(dead_bee.job_id),
         {:ok, new_bee} <-
           create_bee_record(Keyword.get(opts, :name, generate_bee_name()), dead_bee.job_id),
         {:ok, _cell} <- Hive.Cell.adopt(cell.id, new_bee.id),
         :ok <- revive_job(job, new_bee.id),
         prompt = build_revive_prompt(job),
         {:ok, _pid} <-
           start_worker(
             new_bee.id,
             job.id,
             cell.comb_id,
             hive_root,
             Keyword.merge(opts, revive: true, cell_id: cell.id, prompt: prompt)
           ) do
      {:ok, new_bee}
    end
  end

  @doc """
  Lists bees with optional filters.

  ## Options

    * `:status` - filter by status (e.g., "working", "stopped")
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    bees = Store.all(:bees)

    bees =
      case Keyword.get(opts, :status) do
        nil -> bees
        status -> Enum.filter(bees, &(&1.status == status))
      end

    Enum.sort_by(bees, & &1.inserted_at, {:desc, DateTime})
  end

  @doc """
  Gets a bee by ID.

  Returns `{:ok, bee}` or `{:error, :not_found}`.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(bee_id) do
    Store.fetch(:bees, bee_id)
  end

  @doc """
  Gracefully stops a running bee worker.

  Returns `:ok` or `{:error, :not_found}` if the worker process is not running.
  """
  @spec stop(String.t()) :: :ok | {:error, :not_found}
  def stop(bee_id) do
    Hive.Bee.Worker.stop(bee_id)
  end

  # -- Private helpers ---------------------------------------------------------

  defp check_job_ready(job_id) do
    if Hive.Jobs.ready?(job_id), do: :ok, else: {:error, :blocked}
  end

  defp create_bee_record(name, job_id) do
    # Get job to determine model assignment
    model =
      case Hive.Jobs.get(job_id) do
        {:ok, job} ->
          job.assigned_model || job.recommended_model || "claude-sonnet"

        _ ->
          "claude-sonnet"
      end

    record = %{
      name: name,
      status: "starting",
      job_id: job_id,
      cell_path: nil,
      pid: nil,
      assigned_model: model,
      context_tokens_used: 0,
      context_tokens_limit: nil,
      context_percentage: 0.0
    }

    Store.insert(:bees, record)
  end

  defp assign_job(job_id, bee_id) do
    case Hive.Jobs.assign(job_id, bee_id) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_worker(bee_id, job_id, comb_id, hive_root, opts) do
    child_opts =
      [
        bee_id: bee_id,
        job_id: job_id,
        comb_id: comb_id,
        hive_root: hive_root
      ] ++ Keyword.take(opts, [:prompt, :claude_executable])

    Hive.CombSupervisor.start_child({Hive.Bee.Worker, child_opts})
  end

  defp generate_bee_name do
    adjectives = ~w(swift bright keen bold calm sharp)
    nouns = ~w(scout worker forager builder dancer)

    adj = Enum.random(adjectives)
    noun = Enum.random(nouns)
    suffix = :crypto.strong_rand_bytes(2) |> Base.encode16(case: :lower)

    "#{adj}-#{noun}-#{suffix}"
  end

  defp update_bee_working(bee_id, cell) do
    case Store.get(:bees, bee_id) do
      nil ->
        {:error, :bee_not_found}

      bee ->
        updated = Map.merge(bee, %{status: "working", cell_path: cell.worktree_path, pid: nil})
        Store.put(:bees, updated)
        :ok
    end
  end

  defp maybe_transition_job(job_id) do
    case Hive.Jobs.get(job_id) do
      {:ok, %{status: "assigned"}} ->
        case Hive.Jobs.start(job_id) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_ensure_agent(job_id, _comb_id, cell) do
    # Best-effort, don't block spawn on agent generation
    try do
      case Hive.Jobs.get(job_id) do
        {:ok, job} ->
          # Council expert installation
          if Map.get(job, :council_id) && Map.get(job, :council_experts) do
            Hive.Council.install_experts(job.council_id, job.council_experts, cell.worktree_path)
          end

          # Standard comb-level agent
          case Store.get(:combs, cell.comb_id) do
            nil ->
              :ok

            comb when comb.path != nil ->
              Hive.AgentProfile.ensure_agent(comb.path, %{
                title: job.title,
                description: job.description
              })

              Hive.AgentProfile.install_agents(comb.path, cell.worktree_path)
              :ok

            _comb ->
              :ok
          end

        {:error, _} ->
          :ok
      end
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp spawn_model_detached(bee_id, job_id, cell, hive_root) do
    with {:ok, model_path} <- Hive.Runtime.Models.find_executable(),
         {:ok, prompt} <- build_job_prompt(job_id),
         {:ok, plugin} <- Hive.Runtime.Models.resolve_plugin() do
      cmd_line = build_detached_command(plugin, model_path, prompt)

      # Write a wrapper script that runs the model and updates hive on exit
      script_dir = Path.join([hive_root, ".hive", "run"])
      File.mkdir_p!(script_dir)
      script_path = Path.join(script_dir, "#{bee_id}.sh")
      log_path = Path.join(script_dir, "#{bee_id}.log")

      hive_path = System.find_executable("hive") || "hive"

      script_content = """
      #!/bin/bash
      cd "#{cell.worktree_path}"
      #{cmd_line} > "#{log_path}" 2>&1
      EXIT_CODE=$?
      if [ $EXIT_CODE -eq 0 ]; then
        "#{hive_path}" bee complete #{bee_id}
      else
        "#{hive_path}" bee fail #{bee_id} --reason "Exit code $EXIT_CODE"
      fi
      """

      File.write!(script_path, script_content)
      File.chmod!(script_path, 0o755)

      # Spawn detached: nohup + redirect + disown via a subshell
      port =
        Port.open({:spawn, "nohup #{script_path} >/dev/null 2>&1 & echo $!"}, [
          :binary,
          :exit_status
        ])

      os_pid =
        receive do
          {^port, {:data, data}} -> String.trim(data)
          {^port, {:exit_status, _}} -> nil
        after
          5_000 -> nil
        end

      # Drain exit status
      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        2_000 -> :ok
      end

      {:ok, os_pid}
    end
  end

  defp build_detached_command(plugin, model_path, prompt) do
    if function_exported?(plugin, :detached_command, 2) do
      plugin.detached_command(prompt, [])
    else
      ~s("#{model_path}" #{escape_shell(prompt)})
    end
  end

  defp build_job_prompt(job_id) do
    case Hive.Jobs.get(job_id) do
      {:ok, job} ->
        prompt = if job.description, do: "#{job.title}\n\n#{job.description}", else: job.title
        {:ok, prompt}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp escape_shell(str) do
    # Single-quote the string, escaping any single quotes within
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end

  # -- Revive helpers ----------------------------------------------------------

  defp validate_dead(%{status: status}) when status in ["stopped", "crashed"], do: :ok
  defp validate_dead(_bee), do: {:error, :bee_still_active}

  defp find_active_cell(bee_id) do
    case Store.find_one(:cells, fn c -> c.bee_id == bee_id and c.status == "active" end) do
      nil -> {:error, :no_active_cell}
      cell -> {:ok, cell}
    end
  end

  defp validate_worktree_exists(%{worktree_path: path}) do
    if File.dir?(path), do: :ok, else: {:error, :worktree_not_found}
  end

  defp revive_job(%{status: "failed"} = job, new_bee_id) do
    case Hive.Jobs.revive(job.id, new_bee_id) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp revive_job(%{status: "done"}, _new_bee_id), do: :ok

  defp revive_job(job, new_bee_id) do
    # running or assigned — just update the bee_id
    Store.put(:jobs, %{job | bee_id: new_bee_id})
    :ok
  end

  defp build_revive_prompt(job) do
    description = if job.description, do: "\n\n#{job.description}", else: ""

    """
    You are continuing work on: "#{job.title}"#{description}

    IMPORTANT: There is existing work in this worktree from a previous session.
    Your task is to FINALIZE this work, not start over:

    1. Run `git status` and `git diff` to see what changes exist
    2. Review any uncommitted changes for correctness
    3. Commit changes with descriptive commit messages
    4. Run tests or validation if applicable
    5. Report completion when everything is committed and verified

    Do NOT start the work over from scratch. Finalize what's already here.
    """
  end
end
