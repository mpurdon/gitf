defmodule GiTF.Ghosts do
  @moduledoc """
  Context module for managing ghost agents.

  Provides the public API for spawning, listing, and stopping ghosts. This
  module coordinates between the Ghost.Worker GenServer (runtime lifecycle),
  the Archive (persistence), and the SectorSupervisor (process supervision).

  This is a context module: thin orchestration layer over store records
  and supervised processes.
  """

  require Logger

  alias GiTF.Archive

  # -- Public API --------------------------------------------------------------

  @doc """
  Spawns a new ghost to work on a op.

  1. Creates a ghost record in the store
  2. Assigns the op to the ghost
  3. Starts a Ghost.Worker under SectorSupervisor

  ## Options

    * `:name` - human-friendly name (default: auto-generated)
    * `:prompt` - explicit prompt (overrides op description)
    * `:claude_executable` - path to executable (for testing)

  Returns `{:ok, ghost}` or `{:error, reason}`.
  """
  @spec spawn(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def spawn(op_id, sector_id, gitf_root, opts \\ []) do
    name = Keyword.get(opts, :name, generate_ghost_name())

    # Atomic check: reject if op already has a ghost assigned (prevents duplicate spawning)
    with {:check_ready, :ok} <- {:check_ready, check_not_already_assigned(op_id)},
         {:check_ready, :ok} <- {:check_ready, check_job_ready(op_id)},
         {:llm_health, :ok} <- {:llm_health, check_llm_available()},
         {:create_ghost, {:ok, ghost}} <- {:create_ghost, create_ghost_record(name, op_id)},
         {:assign, :ok} <- {:assign, assign_job(op_id, ghost.id)},
         {:start_worker, {:ok, _pid}} <-
           {:start_worker, start_worker(ghost.id, op_id, sector_id, gitf_root, opts)} do
      GiTF.Telemetry.emit([:gitf, :ghost, :spawned], %{}, %{
        ghost_id: ghost.id,
        op_id: op_id,
        sector_id: sector_id
      })

      {:ok, ghost}
    else
      {step, {:error, reason}} ->
        Logger.error("Ghost spawn failed at step #{step} for op #{op_id}: #{inspect(reason)}")

        ghost_id = if match?({:ok, ghost} when is_map(ghost), {:ok, nil}), do: nil, else: get_ghost_id_from_op(op_id)
        cleanup_orphaned_ghost(ghost_id, op_id)

        GiTF.Telemetry.emit([:gitf, :ghost, :spawn_failed], %{}, %{
          ghost_id: ghost_id,
          op_id: op_id,
          sector_id: sector_id,
          step: step,
          reason: inspect(reason)
        })

        {:error, reason}
    end
  end

  @doc """
  Spawns a ghost as a detached OS process (for CLI use).

  Unlike `spawn/4`, this does NOT start a Worker GenServer. Instead it:
  1. Creates a ghost record and assigns the op
  2. Creates a shell (git worktree) directly
  3. Updates ghost status to "working"
  4. Generates settings for the ghost
  5. Spawns Claude as a detached OS process via a wrapper script

  The wrapper script runs Claude headless, then calls `gitf` CLI to
  update the ghost/op status when Claude exits. This avoids keeping
  the escript alive (which would block the store file).

  Returns `{:ok, ghost}` or `{:error, reason}`.
  """
  @spec spawn_detached(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def spawn_detached(op_id, sector_id, gitf_root, opts \\ []) do
    if GiTF.Runtime.ModelResolver.api_mode?() do
      # API mode: use supervised Worker (runs agent loop via API calls).
      # The caller must keep the BEAM alive for the Worker to complete.
      spawn(op_id, sector_id, gitf_root, opts)
    else
      # CLI mode: spawn Claude as a detached OS process that outlives the caller
      spawn_detached_cli(op_id, sector_id, gitf_root, opts)
    end
  end

  defp spawn_detached_cli(op_id, sector_id, gitf_root, opts) do
    name = Keyword.get(opts, :name, generate_ghost_name())

    with {:check_ready, :ok} <- {:check_ready, check_job_ready(op_id)},
         {:llm_health, :ok} <- {:llm_health, check_llm_available()},
         {:create_ghost, {:ok, ghost}} <- {:create_ghost, create_ghost_record(name, op_id)},
         {:assign, :ok} <- {:assign, assign_job(op_id, ghost.id)},
         {:shell, {:ok, shell}} <-
           {:shell, GiTF.Shell.create(sector_id, ghost.id, gitf_root: gitf_root)},
         {:update, :ok} <- {:update, update_bee_working(ghost.id, shell)},
         {:transition, :ok} <- {:transition, maybe_transition_job(op_id)},
         {:agent, :ok} <- {:agent, maybe_ensure_agent(op_id, sector_id, shell)},
         {:dispatch, :ok} <- {:dispatch, write_pre_dispatch(shell.worktree_path, op_id)},
         {:spawn, {:ok, _os_pid}} <-
           {:spawn, spawn_model_detached(ghost.id, op_id, shell, gitf_root)} do
      GiTF.Telemetry.emit([:gitf, :ghost, :spawned], %{}, %{
        ghost_id: ghost.id,
        op_id: op_id,
        sector_id: sector_id
      })

      {:ok, ghost}
    else
      {step, {:error, reason}} ->
        Logger.error(
          "Ghost CLI spawn failed at step #{step} for op #{op_id}: #{inspect(reason)}"
        )

        ghost_id = get_ghost_id_from_op(op_id)
        cleanup_orphaned_ghost(ghost_id, op_id)

        GiTF.Telemetry.emit([:gitf, :ghost, :spawn_failed], %{}, %{
          ghost_id: ghost_id,
          op_id: op_id,
          sector_id: sector_id,
          step: step,
          reason: inspect(reason)
        })

        {:error, reason}
    end
  end

  @doc """
  Revives a dead ghost by spawning a new ghost into its existing worktree.

  The dead ghost must be "stopped" or "crashed". Its shell and worktree are
  reassigned to the new ghost, which receives a prompt instructing it to
  finalize the existing work rather than starting over.

  Returns `{:ok, new_ghost}` or `{:error, reason}`.
  """
  @spec revive(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def revive(dead_ghost_id, gitf_root, opts \\ []) do
    with {:ok, dead_bee} <- get(dead_ghost_id),
         :ok <- validate_dead(dead_bee),
         {:ok, shell} <- find_active_cell(dead_ghost_id),
         :ok <- validate_worktree_exists(shell),
         {:ok, op} <- GiTF.Ops.get(dead_bee.op_id),
         {:ok, new_ghost} <-
           create_ghost_record(Keyword.get(opts, :name, generate_ghost_name()), dead_bee.op_id),
         {:ok, _cell} <- GiTF.Shell.adopt(shell.id, new_ghost.id),
         :ok <- revive_job(op, new_ghost.id),
         prompt = build_revive_prompt(op),
         {:ok, _pid} <-
           start_worker(
             new_ghost.id,
             op.id,
             shell.sector_id,
             gitf_root,
             Keyword.merge(opts, revive: true, shell_id: shell.id, prompt: prompt)
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
    ghosts = Archive.all(:ghosts)

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
    Archive.fetch(:ghosts, ghost_id)
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

  defp check_not_already_assigned(op_id) do
    case GiTF.Ops.get(op_id) do
      {:ok, %{ghost_id: ghost_id}} when is_binary(ghost_id) and ghost_id != "" ->
        {:error, :already_assigned}

      _ ->
        :ok
    end
  end

  defp check_job_ready(op_id) do
    if GiTF.Ops.ready?(op_id), do: :ok, else: {:error, :blocked}
  end

  # Pre-flight check: don't waste a spawn attempt if the LLM circuit breaker is open
  defp check_llm_available do
    case GiTF.CircuitBreaker.get_state("api:llm") do
      :open -> {:error, :circuit_open}
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp create_ghost_record(name, op_id) do
    # Get op to determine model assignment
    default_model = GiTF.Runtime.ModelResolver.resolve("general")

    model =
      case GiTF.Ops.get(op_id) do
        {:ok, op} ->
          raw = op.assigned_model || op.recommended_model || "general"
          GiTF.Runtime.ModelResolver.resolve(raw)

        _ ->
          default_model
      end

    record = %{
      name: name,
      status: "starting",
      op_id: op_id,
      shell_path: nil,
      pid: nil,
      assigned_model: model,
      context_tokens_used: 0,
      context_tokens_limit: nil,
      context_percentage: 0.0
    }

    Archive.insert(:ghosts, record)
  end

  defp assign_job(op_id, ghost_id) do
    case GiTF.Ops.assign(op_id, ghost_id) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_worker(ghost_id, op_id, sector_id, gitf_root, opts) do
    child_opts =
      [
        ghost_id: ghost_id,
        op_id: op_id,
        sector_id: sector_id,
        gitf_root: gitf_root
      ] ++ Keyword.take(opts, [:prompt, :claude_executable])

    GiTF.SectorSupervisor.start_child({GiTF.Ghost.Worker, child_opts})
  end

  defp generate_ghost_name do
    adjectives = ~w(swift bright keen bold calm sharp)
    nouns = ~w(recon worker forager builder dancer)

    adj = Enum.random(adjectives)
    noun = Enum.random(nouns)
    suffix = :crypto.strong_rand_bytes(2) |> Base.encode16(case: :lower)

    "#{adj}-#{noun}-#{suffix}"
  end

  defp update_bee_working(ghost_id, shell) do
    case Archive.get(:ghosts, ghost_id) do
      nil ->
        {:error, :bee_not_found}

      ghost ->
        updated = Map.merge(ghost, %{status: "working", shell_path: shell.worktree_path, pid: nil})
        Archive.put(:ghosts, updated)
        :ok
    end
  end

  defp maybe_transition_job(op_id) do
    case GiTF.Ops.get(op_id) do
      {:ok, %{status: "assigned"}} ->
        case GiTF.Ops.start(op_id) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_ensure_agent(op_id, _sector_id, shell) do
    # Best-effort, don't block spawn on agent generation
    try do
      case GiTF.Ops.get(op_id) do
        {:ok, op} ->
          # Standard sector-level agent
          case Archive.get(:sectors, shell.sector_id) do
            nil ->
              :ok

            sector when sector.path != nil ->
              GiTF.AgentProfile.ensure_agent(sector.path, %{
                title: op.title,
                description: op.description
              })

              GiTF.AgentProfile.install_agents(sector.path, shell.worktree_path)
              :ok

            _sector ->
              :ok
          end

        {:error, _} ->
          :ok
      end
    rescue
      e ->
        require Logger
        Logger.debug("Agent setup failed for op #{op_id}: #{inspect(e)}")
        :ok
    catch
      _, reason ->
        require Logger
        Logger.debug("Agent setup error for op #{op_id}: #{inspect(reason)}")
        :ok
    end
  end

  defp spawn_model_detached(ghost_id, op_id, shell, gitf_root) do
    # Detached CLI spawn always uses the Claude plugin (not API plugins)
    with {:ok, model_path} <- GiTF.Runtime.Claude.find_executable(),
         {:ok, prompt} <- build_job_prompt(op_id),
         {:ok, plugin} <- {:ok, GiTF.Runtime.Claude} do
      cmd_line = build_detached_command(plugin, model_path, prompt)

      # Read risk_level from op for sandbox configuration
      risk_level = job_risk_level(op_id)

      # Apply sandbox if available
      # We wrap the command execution in a shell inside the sandbox
      sandboxed_cmd_line =
        if GiTF.Sandbox.available?() and GiTF.Sandbox.name() != "local" do
          {sandbox_cmd, sandbox_args, _opts} =
            GiTF.Sandbox.wrap_command("sh", ["-c", cmd_line],
              cd: shell.worktree_path, risk_level: risk_level)

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
        try do
          case GiTF.Web.Endpoint.config(:http) do
            [_ | _] = http ->
              port = Keyword.get(http, :port, 4000)
              "export GITF_SERVER=http://localhost:#{port}\n"

            _ ->
              ""
          end
        rescue
          ArgumentError -> ""
        end

      script_content = """
      #!/bin/bash
      unset CLAUDECODE
      #{server_export}cd #{escape_shell(shell.worktree_path)}
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

  defp job_risk_level(op_id) do
    case GiTF.Ops.get(op_id) do
      {:ok, op} -> Map.get(op, :risk_level, :low)
      _ -> :low
    end
  end

  defp build_job_prompt(op_id) do
    case GiTF.Ops.get(op_id) do
      {:ok, op} ->
        prompt = if op.description, do: "#{op.title}\n\n#{op.description}", else: op.title
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

  defp get_ghost_id_from_op(op_id) do
    case GiTF.Ops.get(op_id) do
      {:ok, %{ghost_id: gid}} when is_binary(gid) and gid != "" -> gid
      _ -> nil
    end
  end

  defp cleanup_orphaned_ghost(nil, _op_id), do: :ok

  defp cleanup_orphaned_ghost(ghost_id, op_id) do
    case Archive.get(:ghosts, ghost_id) do
      nil -> :ok
      ghost -> Archive.put(:ghosts, %{ghost | status: "crashed"})
    end

    GiTF.Ops.reset(op_id)
    :ok
  rescue
    _ -> :ok
  end

  # -- Revive helpers ----------------------------------------------------------

  defp validate_dead(%{status: status}) when status in ["stopped", "crashed"], do: :ok
  defp validate_dead(_bee), do: {:error, :bee_still_active}

  defp find_active_cell(ghost_id) do
    case Archive.find_one(:shells, fn c -> c.ghost_id == ghost_id and c.status == "active" end) do
      nil -> {:error, :no_active_cell}
      shell -> {:ok, shell}
    end
  end

  defp validate_worktree_exists(%{worktree_path: path}) do
    if File.dir?(path), do: :ok, else: {:error, :worktree_not_found}
  end

  defp revive_job(%{status: "failed"} = op, new_ghost_id) do
    case GiTF.Ops.revive(op.id, new_ghost_id) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp revive_job(%{status: "done"}, _new_ghost_id), do: :ok

  defp revive_job(op, new_ghost_id) do
    # running or assigned — just update the ghost_id
    Archive.put(:ops, %{op | ghost_id: new_ghost_id})
    :ok
  end

  defp build_revive_prompt(op) do
    description = if op.description, do: "\n\n#{op.description}", else: ""

    """
    You are continuing work on: "#{op.title}"#{description}

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

  defp write_pre_dispatch(worktree_path, op_id) do
    case GiTF.Ops.get(op_id) do
      {:ok, op} ->
        content = build_instructions_content(op)
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

  defp build_instructions_content(op) do
    sections = [
      "# Job Instructions\n",
      "## #{op.title}\n"
    ]

    sections =
      if op.description && op.description != "" do
        sections ++ ["### Description\n\n#{op.description}\n"]
      else
        sections
      end

    sections =
      case Map.get(op, :scout_findings) do
        findings when is_binary(findings) and findings != "" ->
          sections ++ ["### Recon Findings\n\n#{findings}\n"]

        _ ->
          sections
      end

    sections =
      case Map.get(op, :acceptance_criteria) do
        criteria when is_binary(criteria) and criteria != "" ->
          sections ++ ["### Acceptance Criteria\n\n#{criteria}\n"]

        _ ->
          sections
      end

    sections =
      case Map.get(op, :target_files) do
        files when is_list(files) and files != [] ->
          file_list = Enum.map_join(files, "\n", &"- `#{&1}`")
          sections ++ ["### Target Files\n\n#{file_list}\n"]

        _ ->
          sections
      end

    Enum.join(sections, "\n")
  end
end
