defmodule Hive.Queen do
  @moduledoc """
  GenServer for the Queen orchestrator process.

  The Queen coordinates work across bees by subscribing to waggle messages
  and reacting to status updates. This is a thin GenServer -- the business
  logic for waggle processing lives in `Hive.Waggle` and `Hive.Prime`,
  while the Queen merely maintains session state and dispatches reactions.

  ## State

      %{
        status: :idle | :active,
        active_bees: %{bee_id => bee_info},
        hive_root: String.t()
      }

  ## Lifecycle

  The Queen is NOT auto-started by the Application supervisor. It is
  started on-demand when the user runs `hive queen`, and uses a
  `:transient` restart strategy so it stays down if stopped gracefully.
  """

  use GenServer
  require Logger

  @name Hive.Queen
  @waggle_recovery_interval :timer.seconds(30)
  @waggle_stale_seconds 30

  # -- Client API ------------------------------------------------------------

  @doc """
  Starts the Queen GenServer.

  ## Options

    * `:hive_root` - the root directory of the hive workspace (required)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    hive_root = Keyword.fetch!(opts, :hive_root)
    GenServer.start_link(__MODULE__, %{hive_root: hive_root}, name: @name)
  end

  @doc "Activates the Queen session. Sets status to `:active`."
  @spec start_session() :: :ok
  def start_session do
    GenServer.call(@name, :start_session)
  end

  @doc "Deactivates the Queen session. Sets status to `:idle`."
  @spec stop_session() :: :ok
  def stop_session do
    GenServer.call(@name, :stop_session)
  end

  @doc """
  Launches an interactive Claude session for the Queen.

  Sets up the queen workspace with settings, then spawns Claude
  interactively. The GenServer monitors the port and handles its
  messages alongside waggle processing.
  """
  @spec launch() :: :ok | {:error, term()}
  def launch do
    GenServer.call(@name, :launch)
  end

  @doc "Returns the current Queen state for inspection."
  @spec status() :: map()
  def status do
    GenServer.call(@name, :status)
  end

  @doc "Blocks until the Queen's Claude session exits."
  @spec await_session_end() :: :ok
  def await_session_end do
    GenServer.call(@name, :await_session_end, :infinity)
  end

  # -- GenServer callbacks ---------------------------------------------------

  @impl true
  def init(%{hive_root: hive_root}) do
    Logger.metadata(component: :queen)

    # Subscribe to waggle messages addressed to the queen
    Hive.Waggle.subscribe("waggle:queen")

    max_bees = read_max_bees(hive_root)

    state = %{
      status: :idle,
      active_bees: %{},
      hive_root: hive_root,
      port: nil,
      max_bees: max_bees,
      max_retries: 3
    }

    # Best-effort: start Drone alongside Queen (unlinked so it doesn't crash the Queen)
    try do
      name = {:via, Registry, {Hive.Registry, :drone}}
      case GenServer.start(Hive.Drone, [], name: name) do
        {:ok, _pid} -> Logger.info("Drone started alongside Queen")
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> Logger.warning("Could not start Drone: #{inspect(reason)}")
      end
    rescue
      _ -> :ok
    end

    Logger.info("Queen initialized at #{hive_root}")

    # Recover any missed waggles from before we started
    send(self(), :recover_missed_waggles)
    schedule_waggle_recovery()

    # Periodically check for pending jobs that need bees
    schedule_job_spawner()

    {:ok, state}
  end

  @impl true
  def handle_call(:start_session, _from, state) do
    Logger.info("Queen session started")
    {:reply, :ok, %{state | status: :active}}
  end

  def handle_call(:stop_session, _from, state) do
    Logger.info("Queen session stopped")
    {:reply, :ok, %{state | status: :idle}}
  end

  def handle_call(:launch, _from, state) do
    case launch_claude_session(state) do
      {:ok, port} ->
        {:reply, :ok, %{state | port: port, status: :active}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, Map.take(state, [:status, :active_bees, :hive_root, :max_bees]), state}
  end

  def handle_call(:await_session_end, from, state) do
    {:noreply, Map.put(state, :awaiter, from)}
  end

  @impl true
  def handle_info({:waggle_received, waggle}, state) do
    state = handle_waggle(waggle, state)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, _status}}, %{port: port} = state) when is_port(port) do
    Logger.info("Queen's Claude session ended")

    if state[:awaiter] do
      GenServer.reply(state.awaiter, :ok)
    end

    {:noreply, %{state | port: nil, status: :idle, awaiter: nil}}
  end

  # API mode: Task completion
  def handle_info({ref, {:ok, _result}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    Logger.info("Queen's API session completed")

    if state[:awaiter] do
      GenServer.reply(state.awaiter, :ok)
    end

    {:noreply, %{state | port: nil, status: :idle, awaiter: nil}}
  end

  def handle_info({ref, {:error, reason}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    Logger.warning("Queen's API session failed: #{inspect(reason)}")

    if state[:awaiter] do
      GenServer.reply(state.awaiter, :ok)
    end

    {:noreply, %{state | port: nil, status: :idle, awaiter: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    Logger.warning("Queen's API session process died: #{inspect(reason)}")

    if state[:awaiter] do
      GenServer.reply(state.awaiter, :ok)
    end

    {:noreply, %{state | port: nil, status: :idle, awaiter: nil}}
  end

  def handle_info(:recover_missed_waggles, state) do
    state = recover_missed_waggles(state)
    {:noreply, state}
  end

  def handle_info(:schedule_waggle_recovery, state) do
    state = recover_missed_waggles(state)
    schedule_waggle_recovery()
    {:noreply, state}
  end

  def handle_info(:spawn_ready_jobs, state) do
    state = spawn_all_ready_jobs(state)
    schedule_job_spawner()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Queen received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # -- Private: waggle handling ----------------------------------------------
  # Business logic is deliberately minimal here. The Queen GenServer
  # dispatches to pattern-matched handlers. Heavier orchestration logic
  # will move to dedicated context modules as the system grows.

  defp handle_waggle(%{subject: "job_complete"} = waggle, state) do
    Logger.info("Bee #{waggle.from} reports job complete: #{waggle.body}")
    state = update_in(state.active_bees, &Map.delete(&1, waggle.from))
    advance_quest(waggle.from, state)
  end

  defp handle_waggle(%{subject: "job_failed"} = waggle, state) do
    Logger.warning("Bee #{waggle.from} reports job failed: #{waggle.body}")
    state = update_in(state.active_bees, &Map.delete(&1, waggle.from))
    maybe_retry_job(waggle, state)
  end

  defp handle_waggle(%{subject: "validation_failed"} = waggle, state) do
    Logger.warning("Bee #{waggle.from} reports validation failed: #{waggle.body}")
    state = update_in(state.active_bees, &Map.delete(&1, waggle.from))
    maybe_retry_job(waggle, state)
  end

  defp handle_waggle(%{subject: "merge_conflict_warning"} = waggle, state) do
    Logger.warning("Merge conflict detected from bee #{waggle.from}: #{waggle.body}")

    # Extract cell_id from the bee record
    cell_id =
      case Hive.Bees.get(waggle.from) do
        {:ok, bee} ->
          case Hive.Store.find_one(:cells, fn c -> c.bee_id == bee.id end) do
            nil -> nil
            cell -> cell.id
          end

        _ ->
          nil
      end

    if cell_id do
      # Attempt rebase-based resolution
      case Hive.Conflict.resolve(cell_id, :rebase) do
        {:ok, :resolved} ->
          Logger.info("Conflict resolved via rebase for cell #{cell_id}")

          # Re-attempt merge after successful rebase
          case Hive.Merge.merge_back(cell_id) do
            {:ok, strategy} ->
              Logger.info("Post-rebase merge succeeded (#{strategy}) for cell #{cell_id}")

            {:error, reason} ->
              Logger.warning("Post-rebase merge failed for cell #{cell_id}: #{inspect(reason)}")
              mark_needs_manual_merge(cell_id, waggle)
          end

        {:error, reason} ->
          Logger.warning("Conflict resolution failed for cell #{cell_id}: #{inspect(reason)}")
          mark_needs_manual_merge(cell_id, waggle)
      end
    else
      Logger.warning("Could not find cell for bee #{waggle.from}, conflict unresolved")
    end

    state
  end

  defp handle_waggle(%{subject: "merge_failed"} = waggle, state) do
    Logger.warning("Merge failed from bee #{waggle.from}: #{waggle.body}")
    state
  end

  defp handle_waggle(%{subject: "quest_advance"} = waggle, state) do
    # Handle quest phase advancement requests
    quest_id = waggle.body
    case Hive.Queen.Orchestrator.advance_quest(quest_id) do
      {:ok, new_phase} ->
        Logger.info("Quest #{quest_id} advanced to #{new_phase} phase")
      {:error, reason} ->
        Logger.warning("Failed to advance quest #{quest_id}: #{inspect(reason)}")
    end
    state
  end

  defp handle_waggle(waggle, state) do
    Logger.debug("Queen received waggle from #{waggle.from}: #{waggle.subject}")
    state
  end

  # -- Private: retry logic ---------------------------------------------------

  defp maybe_retry_job(waggle, state) do
    case Hive.Bees.get(waggle.from) do
      {:ok, bee} when not is_nil(bee.job_id) ->
        job_id = bee.job_id

        # Read persisted retry count from job record (survives Queen restarts)
        attempts =
          case Hive.Jobs.get(job_id) do
            {:ok, job} -> Map.get(job, :retry_count, 0)
            _ -> 0
          end

        if attempts < state.max_retries do
          Logger.info("Retrying job #{job_id} (attempt #{attempts + 1}/#{state.max_retries})")

          case Hive.Jobs.reset(job_id) do
            {:ok, job} ->
              # Check budget before spawning retry
              case check_quest_budget(job.quest_id) do
                :ok ->
                  case Hive.Bees.spawn(job_id, job.comb_id, state.hive_root) do
                    {:ok, _bee} ->
                      state

                    {:error, reason} ->
                      Logger.warning("Retry spawn failed for job #{job_id}: #{inspect(reason)}")
                      state
                  end

                {:error, :budget_exceeded} ->
                  Logger.warning("Budget exceeded for quest #{job.quest_id}, skipping retry")

                  Hive.Waggle.send(
                    "queen",
                    "queen",
                    "budget_exceeded",
                    "Quest #{job.quest_id} budget exceeded, job #{job_id} retry skipped"
                  )

                  state
              end

            {:error, reason} ->
              Logger.warning("Could not reset job #{job_id} for retry: #{inspect(reason)}")
              state
          end
        else
          Logger.warning("Job #{job_id} exhausted #{state.max_retries} retries")
          best_effort_update_quest_status(job_id)
          state
        end

      _ ->
        state
    end
  end

  # -- Private: quest advancement -----------------------------------------------

  defp advance_quest(bee_id, state) do
    with {:ok, bee} <- Hive.Bees.get(bee_id),
         true <- not is_nil(bee.job_id),
         {:ok, job} <- Hive.Jobs.get(bee.job_id) do
      quest_id = job.quest_id
      Hive.Quests.update_status!(quest_id)

      # Try to advance quest through orchestrator
      case Hive.Queen.Orchestrator.advance_quest(quest_id) do
        {:ok, "completed"} ->
          Logger.info("Quest completed: #{quest_id}")
          Hive.Waggle.send(
            "system",
            "queen",
            "quest_completed",
            "Quest #{quest_id} — all jobs done"
          )
          state

        {:ok, _new_phase} ->
          # Orchestrator returned a non-completed phase; check actual quest status
          # in case update_status! already marked it completed (simple quests
          # without the phase system)
          case Hive.Quests.get(quest_id) do
            {:ok, %{status: "completed"} = quest} ->
              Logger.info("Quest completed: #{quest.name} (#{quest_id})")
              Hive.Waggle.send(
                "system",
                "queen",
                "quest_completed",
                "Quest \"#{quest.name}\" (#{quest_id}) — all jobs done"
              )
              state

            {:ok, quest} ->
              spawn_ready_jobs(quest, state)

            _ ->
              state
          end

        {:error, _reason} ->
          # Fall back to original logic
          case Hive.Quests.get(quest_id) do
            {:ok, %{status: "completed"} = quest} ->
              Logger.info("Quest completed: #{quest.name} (#{quest_id})")
              Hive.Waggle.send(
                "system",
                "queen",
                "quest_completed",
                "Quest \"#{quest.name}\" (#{quest_id}) — all jobs done"
              )
              state

            {:ok, quest} ->
              spawn_ready_jobs(quest, state)

            _ ->
              state
          end
      end
    else
      _ -> state
    end
  end

  defp best_effort_update_quest_status(job_id) do
    with {:ok, job} <- Hive.Jobs.get(job_id) do
      Hive.Quests.update_status!(job.quest_id)
    end
  rescue
    _ -> :ok
  end

  defp spawn_ready_jobs(%{status: "planning"}, state), do: state

  defp spawn_ready_jobs(quest, state) do
    # Check budget proactively before spawning
    case check_quest_budget(quest.id) do
      {:error, :budget_exceeded} ->
        Logger.warning("Budget exceeded for quest #{quest.id}, skipping spawn")
        state

      :ok ->
        pending_jobs =
          quest.jobs
          |> Enum.filter(&(&1.status == "pending"))
          |> Enum.filter(&Hive.Jobs.ready?(&1.id))

        active_count = Hive.Bees.list(status: "working") |> length()
        available_slots = max(state.max_bees - active_count, 0)

        pending_jobs
        |> Enum.take(available_slots)
        |> Enum.reduce(state, fn job, acc ->
          case Hive.Bees.spawn_detached(job.id, job.comb_id, acc.hive_root) do
            {:ok, bee} ->
              Logger.info("Auto-spawned bee #{bee.id} for job #{job.id} (#{job.title})")
              acc

            {:error, reason} ->
              Logger.warning("Failed to auto-spawn bee for job #{job.id}: #{inspect(reason)}")
              acc
          end
        end)
    end
  end

  defp check_quest_budget(quest_id) do
    case Hive.Budget.check(quest_id) do
      {:ok, _remaining} -> :ok
      {:error, :budget_exceeded, _spent} -> {:error, :budget_exceeded}
    end
  rescue
    _ -> :ok
  end

  # -- Private: periodic job spawning ------------------------------------------

  @job_spawn_interval :timer.seconds(15)

  defp schedule_job_spawner do
    Process.send_after(self(), :spawn_ready_jobs, @job_spawn_interval)
  end

  defp spawn_all_ready_jobs(state) do
    quests = Hive.Store.all(:quests)
    all_jobs = Hive.Store.all(:jobs)

    Enum.reduce(quests, state, fn quest, acc ->
      if quest.status in ["active", "pending", "planning", "research", "implementation"] do
        # Attach jobs to quest (they're stored separately)
        quest_jobs = Enum.filter(all_jobs, fn j -> j.quest_id == quest.id end)
        quest_with_jobs = Map.put(quest, :jobs, quest_jobs)
        spawn_ready_jobs(quest_with_jobs, acc)
      else
        acc
      end
    end)
  rescue
    e ->
      Logger.warning("Job spawner error: #{Exception.message(e)}")
      state
  end

  # -- Private: waggle recovery ------------------------------------------------

  defp schedule_waggle_recovery do
    Process.send_after(self(), :schedule_waggle_recovery, @waggle_recovery_interval)
  end

  defp recover_missed_waggles(state) do
    cutoff = DateTime.add(DateTime.utc_now(), -@waggle_stale_seconds, :second)

    unread =
      Hive.Waggle.list(to: "queen", read: false)
      |> Enum.filter(fn w ->
        DateTime.compare(w.inserted_at, cutoff) == :lt
      end)

    Enum.reduce(unread, state, fn waggle, acc ->
      Logger.info("Recovering missed waggle: #{waggle.subject} from #{waggle.from}")
      Hive.Waggle.mark_read(waggle.id)
      handle_waggle(waggle, acc)
    end)
  rescue
    e ->
      Logger.warning("Waggle recovery failed: #{Exception.message(e)}")
      state
  end

  # -- Private: Claude session management ------------------------------------

  defp launch_claude_session(state) do
    if Hive.Runtime.ModelResolver.api_mode?() do
      launch_api_session(state)
    else
      launch_cli_session(state)
    end
  end

  defp launch_cli_session(state) do
    queen_workspace = queen_workspace_path(state.hive_root)

    with :ok <- File.mkdir_p(queen_workspace),
         :ok <- setup_sparse_checkout(queen_workspace, state.hive_root),
         :ok <- maybe_generate_settings(:queen, state.hive_root, queen_workspace) do
      Hive.Runtime.Models.spawn_interactive(queen_workspace)
    end
  end

  defp launch_api_session(state) do
    queen_workspace = queen_workspace_path(state.hive_root)
    File.mkdir_p!(queen_workspace)

    # In API mode, start an agent loop task with queen tools
    task = Task.async(fn ->
      Hive.Runtime.AgentLoop.run(
        "You are the Queen orchestrator for a Hive of AI coding agents. " <>
          "Monitor active quests, manage bee workers, and coordinate work.",
        queen_workspace,
        tool_set: :queen,
        max_iterations: 200,
        model: Hive.Runtime.ModelResolver.resolve("opus")
      )
    end)

    {:ok, task}
  end

  defp setup_sparse_checkout(queen_workspace, hive_root) do
    if Hive.Git.repo?(hive_root) do
      case Hive.Git.sparse_checkout_init(queen_workspace) do
        :ok ->
          case Hive.Git.sparse_checkout_set(queen_workspace, [".hive"]) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning("Sparse checkout set failed: #{reason}")
              :ok
          end

        {:error, reason} ->
          Logger.warning("Sparse checkout init failed: #{reason}")
          :ok
      end
    else
      :ok
    end
  end

  defp queen_workspace_path(hive_root) do
    Path.join([hive_root, ".hive", "queen"])
  end

  defp maybe_generate_settings(:queen, hive_root, workspace) do
    case Hive.Runtime.Models.workspace_setup("queen", hive_root) do
      nil ->
        :ok

      settings ->
        claude_dir = Path.join(workspace, ".claude")
        settings_path = Path.join(claude_dir, "settings.json")

        with :ok <- File.mkdir_p(claude_dir),
             json = Jason.encode!(settings, pretty: true),
             :ok <- File.write(settings_path, json) do
          :ok
        end
    end
  end

  defp mark_needs_manual_merge(cell_id, waggle) do
    case Hive.Store.get(:cells, cell_id) do
      nil -> :ok
      cell ->
        Hive.Store.put(:cells, Map.put(cell, :needs_manual_merge, true))
    end

    Hive.Waggle.send(
      "queen",
      "queen",
      "manual_merge_needed",
      "Cell #{cell_id} from bee #{waggle.from} needs manual merge: #{waggle.body}"
    )
  rescue
    _ -> :ok
  end

  defp read_max_bees(hive_root) do
    config_path = Path.join([hive_root, ".hive", "config.toml"])

    case Hive.Config.read_config(config_path) do
      {:ok, config} -> get_in(config, ["queen", "max_bees"]) || 5
      {:error, _} -> 5
    end
  end
end
