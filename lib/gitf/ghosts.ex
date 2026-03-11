defmodule GiTF.Ghosts do
  @moduledoc """
  Context module for managing ghost agents.

  Provides the public API for spawning, listing, and stopping ghosts. This
  module coordinates between the Ghost.Worker GenServer (runtime lifecycle),
  the Store (persistence), and the CombSupervisor (process supervision).

  This is a context module: thin orchestration layer over store records
  and supervised processes.
  """

  alias GiTF.Store

  # -- Public API --------------------------------------------------------------

  @doc """
  Spawns a new ghost to work on a job.

  1. Creates a ghost record in the store
  2. Assigns the job to the ghost
  3. Starts a Ghost.Worker under CombSupervisor

  ## Options

    * `:name` - human-friendly name (default: auto-generated)
    * `:prompt` - explicit prompt (overrides job description)
    * `:claude_executable` - path to executable (for testing)

  Returns `{:ok, ghost}` or `{:error, reason}`.
  """
  @spec spawn(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def spawn(job_id, comb_id, gitf_root, opts \\ []) do
    name = Keyword.get(opts, :name, generate_ghost_name())

    # Atomic check: reject if job already has a ghost assigned (prevents duplicate spawning)
    with :ok <- check_not_already_assigned(job_id),
         :ok <- check_job_ready(job_id),
         {:ok, ghost} <- create_ghost_record(name, job_id),
         :ok <- assign_job(job_id, ghost.id),
         {:ok, _pid} <- start_worker(ghost.id, job_id, comb_id, gitf_root, opts) do
      GiTF.Telemetry.emit([:gitf, :ghost, :spawned], %{}, %{
        ghost_id: ghost.id,
        job_id: job_id,
        comb_id: comb_id
      })

      {:ok, ghost}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Spawns a ghost as a detached OS process (for CLI use).

  Unlike `spawn/4`, this does NOT start a Worker GenServer. Instead it:
  1. Creates a ghost record and assigns the job
  2. Creates a cell (git worktree) directly
  3. Updates ghost status to "working"
  4. Generates settings for the ghost
  5. Spawns Claude as a detached OS process via a wrapper script

  The wrapper script runs Claude headless, then calls `gitf` CLI to
  update the ghost/job status when Claude exits. This avoids keeping
  the escript alive (which would block the store file).

  Returns `{:ok, ghost}` or `{:error, reason}`.
  """
  @spec spawn_detached(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def spawn_detached(job_id, comb_id, gitf_root, opts \\ []) do
    # In API mode, there's no process to detach from — use supervised Worker
    if GiTF.Runtime.ModelResolver.api_mode?() do
      spawn(job_id, comb_id, gitf_root, opts)
    else
      spawn_detached_cli(job_id, comb_id, gitf_root, opts)
    end
  end

  defp spawn_detached_cli(job_id, comb_id, gitf_root, opts) do
    name = Keyword.get(opts, :name, generate_ghost_name())

    with :ok <- check_job_ready(job_id),
         {:ok, ghost} <- create_ghost_record(name, job_id),
         :ok <- assign_job(job_id, ghost.id),
         {:ok, cell} <- GiTF.Cell.create(comb_id, ghost.id, gitf_root: gitf_root),
         :ok <- update_bee_working(ghost.id, cell),
         :ok <- maybe_transition_job(job_id),
         :ok <- maybe_ensure_agent(job_id, comb_id, cell),
         :ok <- write_pre_dispatch(cell.worktree_path, job_id),
         {:ok, _os_pid} <- spawn_model_detached(ghost.id, job_id, cell, gitf_root) do
      {:ok, ghost}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Revives a dead ghost by spawning a new ghost into its existing worktree.

  The dead ghost must be "stopped" or "crashed". Its cell and worktree are
  reassigned to the new ghost, which receives a prompt instructing it to
  finalize the existing work rather than starting over.

  Returns `{:ok, new_ghost}` or `{:error, reason}`.
  """
  @spec revive(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def revive(dead_ghost_id, gitf_root, opts \\ []) do
    with {:ok, dead_bee} <- get(dead_ghost_id),
         :ok <- validate_dead(dead_bee),
         {:ok, cell} <- find_active_cell(dead_ghost_id),
         :ok <- validate_worktree_exists(cell),
         {:ok, job} <- GiTF.Jobs.get(dead_bee.job_id),
         {:ok, new_ghost} <-
           create_ghost_record(Keyword.get(opts, :name, generate_ghost_name()), dead_bee.job_id),
         {:ok, _cell} <- GiTF.Cell.adopt(cell.id, new_ghost.id),
         :ok <- revive_job(job, new_ghost.id),
         prompt = build_revive_prompt(job),
         {:ok, _pid} <-
           start_worker(
             new_ghost.id,
             job.id,
             cell.comb_id,
             gitf_root,
             Keyword.merge(opts, revive: true, cell_id: cell.id, prompt: prompt)
           ) do
      {:ok, new_ghost}
    end
  end

  @doc """
  Lists ghosts with optional filters.

  ## Options

    * `:status` - filter by status (e.g., "working", "stopped")
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    ghosts = Store.all(:ghosts)

    ghosts =
      case Keyword.get(opts, :status) do
        nil -> ghosts
        status -> Enum.filter(ghosts, &(&1.status == status))
      end

    Enum.sort_by(ghosts, & &1.inserted_at, {:desc, DateTime})
  end

  @doc """
  Gets a ghost by ID.

  Returns `{:ok, ghost}` or `{:error, :not_found}`.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(ghost_id) do
    Store.fetch(:ghosts, ghost_id)
  end

  @doc """
  Gracefully stops a running ghost worker.

  Returns `:ok` or `{:error, :not_found}` if the worker process is not running.
  """
  @spec stop(String.t()) :: :ok | {:error, :not_found}
  def stop(ghost_id) do
    GiTF.Ghost.Worker.stop(ghost_id)
  end

  # -- Private helpers ---------------------------------------------------------

  defp check_not_already_assigned(job_id) do
    case GiTF.Jobs.get(job_id) do
      {:ok, %{ghost_id: ghost_id}} when is_binary(ghost_id) and ghost_id != "" ->
        {:error, :already_assigned}

      _ ->
        :ok
    end
  end

  defp check_job_ready(job_id) do
    if GiTF.Jobs.ready?(job_id), do: :ok, else: {:error, :blocked}
  end

  defp create_ghost_record(name, job_id) do
    # Get job to determine model assignment
    model =
      case GiTF.Jobs.get(job_id) do
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

    Store.insert(:ghosts, record)
  end

  defp assign_job(job_id, ghost_id) do
    case GiTF.Jobs.assign(job_id, ghost_id) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_worker(ghost_id, job_id, comb_id, gitf_root, opts) do
    child_opts =
      [
        ghost_id: ghost_id,
        job_id: job_id,
        comb_id: comb_id,
        gitf_root: gitf_root
      ] ++ Keyword.take(opts, [:prompt, :claude_executable])

    GiTF.CombSupervisor.start_child({GiTF.Ghost.Worker, child_opts})
  end

  defp generate_ghost_name do
    adjectives = ~w(swift bright keen bold calm sharp)
    nouns = ~w(scout worker forager builder dancer)

    adj = Enum.random(adjectives)
    noun = Enum.random(nouns)
    suffix = :crypto.strong_rand_bytes(2) |> Base.encode16(case: :lower)

    "#{adj}-#{noun}-#{suffix}"
  end

  defp update_bee_working(ghost_id, cell) do
    case Store.get(:ghosts, ghost_id) do
      nil ->
        {:error, :bee_not_found}

      ghost ->
        updated = Map.merge(ghost, %{status: "working", cell_path: cell.worktree_path, pid: nil})
        Store.put(:ghosts, updated)
        :ok
    end
  end

  defp maybe_transition_job(job_id) do
    case GiTF.Jobs.get(job_id) do
      {:ok, %{status: "assigned"}} ->
        case GiTF.Jobs.start(job_id) do
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
      case GiTF.Jobs.get(job_id) do
        {:ok, job} ->
          # Standard comb-level agent
          case Store.get(:combs, cell.comb_id) do
            nil ->
              :ok

            comb when comb.path != nil ->
              GiTF.AgentProfile.ensure_agent(comb.path, %{
                title: job.title,
                description: job.description
              })

              GiTF.AgentProfile.install_agents(comb.path, cell.worktree_path)
              :ok

            _comb ->
              :ok
          end

        {:error, _} ->
          :ok
      end
    rescue
      e ->
        require Logger
        Logger.debug("Agent setup failed for job #{job_id}: #{inspect(e)}")
        :ok
    catch
      _, reason ->
        require Logger
        Logger.debug("Agent setup error for job #{job_id}: #{inspect(reason)}")
        :ok
    end
  end

  defp spawn_model_detached(ghost_id, job_id, cell, gitf_root) do
    with {:ok, model_path} <- GiTF.Runtime.Models.find_executable(),
         {:ok, prompt} <- build_job_prompt(job_id),
         {:ok, plugin} <- GiTF.Runtime.Models.resolve_plugin() do
      cmd_line = build_detached_command(plugin, model_path, prompt)

      # Read risk_level from job for sandbox configuration
      risk_level = job_risk_level(job_id)

      # Apply sandbox if available
      # We wrap the command execution in a shell inside the sandbox
      sandboxed_cmd_line =
        if GiTF.Sandbox.available?() and GiTF.Sandbox.name() != "local" do
          {sandbox_cmd, sandbox_args, _opts} =
            GiTF.Sandbox.wrap_command("sh", ["-c", cmd_line],
              cd: cell.worktree_path, risk_level: risk_level)

          GiTF.Sandbox.to_shell_string(sandbox_cmd, sandbox_args)
        else
          cmd_line
        end

      # Write a wrapper script that runs the model and updates section on exit
      script_dir = Path.join([gitf_root, ".gitf", "run"])
      File.mkdir_p!(script_dir)
      script_path = Path.join(script_dir, "#{ghost_id}.sh")
      log_path = Path.join(script_dir, "#{ghost_id}.log")

      section_path = System.find_executable("gitf") || "gitf"

      # When spawned from a running server, tell the ghost's section CLI calls
      # to use remote mode so they don't try to boot a second server.
      server_export =
        case GiTF.Web.Endpoint.config(:http) do
          [_ | _] = http ->
            port = Keyword.get(http, :port, 4000)
            "export GITF_SERVER=http://localhost:#{port}\n"

          _ ->
            ""
        end

      script_content = """
      #!/bin/bash
      unset CLAUDECODE
      #{server_export}cd #{escape_shell(cell.worktree_path)}
      #{sandboxed_cmd_line} > #{escape_shell(log_path)} 2>&1
      EXIT_CODE=$?
      if [ $EXIT_CODE -eq 0 ]; then
        #{escape_shell(section_path)} ghost complete #{escape_shell(ghost_id)}
      else
        #{escape_shell(section_path)} ghost fail #{escape_shell(ghost_id)} --reason "Exit code $EXIT_CODE"
      fi
      """

      case File.write(script_path, script_content) do
        :ok -> :ok
        {:error, reason} -> throw({:script_write_failed, reason})
      end

      case File.chmod(script_path, 0o755) do
        :ok -> :ok
        {:error, reason} -> throw({:script_chmod_failed, reason})
      end

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
          5_000 ->
            # Timeout — ensure port is closed to prevent leak
            catch_port_close(port)
            nil
        end

      # Drain exit status
      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        2_000 ->
          catch_port_close(port)
          :ok
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

  defp job_risk_level(job_id) do
    case GiTF.Jobs.get(job_id) do
      {:ok, job} -> Map.get(job, :risk_level, :low)
      _ -> :low
    end
  end

  defp build_job_prompt(job_id) do
    case GiTF.Jobs.get(job_id) do
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

  defp catch_port_close(port) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end
  end

  # -- Revive helpers ----------------------------------------------------------

  defp validate_dead(%{status: status}) when status in ["stopped", "crashed"], do: :ok
  defp validate_dead(_bee), do: {:error, :bee_still_active}

  defp find_active_cell(ghost_id) do
    case Store.find_one(:cells, fn c -> c.ghost_id == ghost_id and c.status == "active" end) do
      nil -> {:error, :no_active_cell}
      cell -> {:ok, cell}
    end
  end

  defp validate_worktree_exists(%{worktree_path: path}) do
    if File.dir?(path), do: :ok, else: {:error, :worktree_not_found}
  end

  defp revive_job(%{status: "failed"} = job, new_ghost_id) do
    case GiTF.Jobs.revive(job.id, new_ghost_id) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp revive_job(%{status: "done"}, _new_ghost_id), do: :ok

  defp revive_job(job, new_ghost_id) do
    # running or assigned — just update the ghost_id
    Store.put(:jobs, %{job | ghost_id: new_ghost_id})
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

  # -- Pre-dispatch helpers ----------------------------------------------------

  defp write_pre_dispatch(worktree_path, job_id) do
    case GiTF.Jobs.get(job_id) do
      {:ok, job} ->
        content = build_instructions_content(job)
        instructions_path = Path.join([worktree_path, ".claude", "instructions.md"])
        File.mkdir_p(Path.dirname(instructions_path))
        File.write(instructions_path, content)
        :ok

      {:error, _} ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp build_instructions_content(job) do
    sections = [
      "# Job Instructions\n",
      "## #{job.title}\n"
    ]

    sections =
      if job.description && job.description != "" do
        sections ++ ["### Description\n\n#{job.description}\n"]
      else
        sections
      end

    sections =
      case Map.get(job, :scout_findings) do
        findings when is_binary(findings) and findings != "" ->
          sections ++ ["### Scout Findings\n\n#{findings}\n"]

        _ ->
          sections
      end

    sections =
      case Map.get(job, :acceptance_criteria) do
        criteria when is_binary(criteria) and criteria != "" ->
          sections ++ ["### Acceptance Criteria\n\n#{criteria}\n"]

        _ ->
          sections
      end

    sections =
      case Map.get(job, :target_files) do
        files when is_list(files) and files != [] ->
          file_list = Enum.map_join(files, "\n", &"- `#{&1}`")
          sections ++ ["### Target Files\n\n#{file_list}\n"]

        _ ->
          sections
      end

    Enum.join(sections, "\n")
  end
end
