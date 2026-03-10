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
    Hive.Logger.set_queen_context()

    # Subscribe to waggle messages addressed to the queen
    Hive.Waggle.subscribe("waggle:queen")

    max_bees = read_max_bees(hive_root)

    state = %{
      status: :idle,
      active_bees: %{},
      hive_root: hive_root,
      port: nil,
      max_bees: max_bees,
      max_retries: 3,
      last_checkpoint: %{},
      stall_timeout: :timer.minutes(10),
      pending_verifications: %{}
    }

    # Drone is now supervised by Application — just verify it's running
    case Hive.Drone.lookup() do
      {:ok, _pid} -> Logger.debug("Drone is running")
      :error -> Logger.warning("Drone is not running")
    end

    Logger.info("Queen initialized at #{hive_root}")

    # Recover stuck jobs whose worker processes died
    recover_stuck_jobs()

    # Recover any missed waggles from before we started
    send(self(), :recover_missed_waggles)
    schedule_waggle_recovery()

    # Periodically check for pending jobs that need bees
    schedule_job_spawner()

    # Periodically check for stalled bees
    schedule_stall_check()

    # Periodically recover stuck jobs (workers died without waggle)
    schedule_stuck_recovery()

    # Periodically check post-review windows
    schedule_post_review_check()

    # Periodically advance stuck quest phases
    schedule_phase_advancement()

    # On startup, resume active quests that may have stalled during crash
    Process.send_after(self(), :resume_active_quests, 10_000)

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

  def handle_info({ref, {:verification_passed, bee_id, job_id}}, state) do
    # Flush task monitor
    Process.demonitor(ref, [:flush])
    state = %{state | pending_verifications: Map.delete(state.pending_verifications, ref)}
    Logger.info("Verification passed for job #{job_id} (bee #{bee_id})")
    notify_run_job_completed(job_id)
    Hive.Reputation.update_after_job(job_id)
    state = advance_quest(bee_id, state)
    {:noreply, state}
  end

  def handle_info({ref, {:verification_failed, bee_id, job_id, result}}, state) do
    Process.demonitor(ref, [:flush])
    state = %{state | pending_verifications: Map.delete(state.pending_verifications, ref)}
    Logger.warning("Verification failed for job #{job_id}: #{inspect(result[:output])}")
    notify_run_job_failed(job_id)
    Hive.Reputation.update_after_job(job_id)

    # Treat as job failure -> trigger retry logic
    waggle = %{
      from: bee_id,
      subject: "verification_failed",
      body: "Verification failed: #{result[:output]}"
    }
    state = maybe_retry_job(waggle, state)
    {:noreply, state}
  end

  def handle_info({ref, {:verification_error, bee_id, job_id, reason}}, state) do
    Process.demonitor(ref, [:flush])
    state = %{state | pending_verifications: Map.delete(state.pending_verifications, ref)}
    Logger.error("Verification system error for job #{job_id}: #{inspect(reason)}")

    # Fail safe: retry
    waggle = %{
      from: bee_id,
      subject: "verification_error",
      body: "System error during verification: #{inspect(reason)}"
    }
    state = maybe_retry_job(waggle, state)
    {:noreply, state}
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

  def handle_info(:check_stalls, state) do
    detect_stalled_bees(state)
    schedule_stall_check()
    {:noreply, state}
  end

  def handle_info(:recover_stuck, state) do
    recover_stuck_jobs()
    timeout_stale_jobs()
    schedule_stuck_recovery()
    {:noreply, state}
  end

  def handle_info(:check_post_reviews, state) do
    check_post_reviews()
    schedule_post_review_check()
    {:noreply, state}
  end

  def handle_info(:advance_stuck_phases, state) do
    advance_stuck_quest_phases()
    schedule_phase_advancement()
    {:noreply, state}
  end

  def handle_info(:resume_active_quests, state) do
    resume_active_quests(state)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Queen received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # -- Private: stuck job recovery --------------------------------------------

  defp recover_stuck_jobs do
    stuck_jobs =
      Hive.Store.filter(:jobs, fn j -> j.status == "running" end)

    Enum.each(stuck_jobs, fn job ->
      worker_alive? =
        case job.bee_id do
          nil -> false
          bee_id ->
            case Hive.Bee.Worker.lookup(bee_id) do
              {:ok, pid} -> Process.alive?(pid)
              :error -> false
            end
        end

      unless worker_alive? do
        Logger.warning("Recovering stuck job #{job.id} (worker dead)")
        Hive.Jobs.fail(job.id)
      end
    end)
  rescue
    e ->
      Logger.warning("Stuck job recovery failed: #{Exception.message(e)}")
  end

  # -- Private: job state timeout detection ------------------------------------

  @pending_timeout_seconds 600
  @assigned_timeout_seconds 600

  defp timeout_stale_jobs do
    now = DateTime.utc_now()

    # Timeout jobs stuck in "pending" for too long (>10 min)
    Hive.Store.filter(:jobs, fn j -> j.status == "pending" end)
    |> Enum.each(fn job ->
      age = DateTime.diff(now, job.updated_at || job.inserted_at, :second)

      if age > @pending_timeout_seconds do
        # Only fail if the job is supposed to be active (has a quest that's running)
        quest_active? =
          case Hive.Store.get(:quests, job.quest_id) do
            %{status: s} when s in ["active", "implementation"] -> true
            _ -> false
          end

        if quest_active? and Hive.Jobs.ready?(job.id) do
          Logger.warning("Job #{job.id} stuck pending for #{age}s, resetting")
          Hive.Jobs.fail(job.id)
          Hive.Jobs.reset(job.id, "Timed out in pending state after #{age}s")
        end
      end
    end)

    # Timeout jobs stuck in "assigned" (bee never started working)
    Hive.Store.filter(:jobs, fn j -> j.status == "assigned" end)
    |> Enum.each(fn job ->
      age = DateTime.diff(now, job.updated_at || job.inserted_at, :second)

      if age > @assigned_timeout_seconds do
        Logger.warning("Job #{job.id} stuck assigned for #{age}s, failing for retry")
        Hive.Jobs.fail(job.id)
      end
    end)
  rescue
    e ->
      Logger.warning("Job timeout check failed: #{Exception.message(e)}")
  end

  # -- Private: waggle handling ----------------------------------------------
  # Business logic is deliberately minimal here. The Queen GenServer
  # dispatches to pattern-matched handlers. Heavier orchestration logic
  # will move to dedicated context modules as the system grows.

  defp handle_waggle(%{subject: "job_complete"} = waggle, state) do
    Logger.info("Bee #{waggle.from} reports job complete. Initiating verification...")

    # We remove from active_bees immediately so Queen doesn't think it's still "working"
    # but we don't advance quest yet.
    state = update_in(state.active_bees, &Map.delete(&1, waggle.from))

    job_id = find_job_for_bee(waggle.from)

    if job_id do
      # Phase jobs (research, design, etc.) don't need verification — skip straight to advance
      case Hive.Jobs.get(job_id) do
        {:ok, %{phase_job: true}} ->
          Logger.info("Phase job #{job_id} completed, skipping verification")
          notify_run_job_completed(job_id)
          state = advance_quest(waggle.from, state)
          state

        {:ok, %{verification_status: vs}} when vs in ["passed", "failed"] ->
          # Already verified (e.g., by worker inline) — skip Queen-side verification
          Logger.info("Job #{job_id} already verified (#{vs}), skipping duplicate verification")
          if vs == "passed" do
            notify_run_job_completed(job_id)
            Hive.Reputation.update_after_job(job_id)
            advance_quest(waggle.from, state)
          else
            notify_run_job_failed(job_id)
            waggle_msg = %{from: waggle.from, subject: "verification_failed", body: "Already failed verification"}
            maybe_retry_job(waggle_msg, state)
          end

        _ ->
          # Implementation jobs go through verification
          task = Task.async(fn ->
            case Hive.Verification.verify_job(job_id) do
              {:ok, :pass, _result} -> {:verification_passed, waggle.from, job_id}
              {:ok, :fail, result} -> {:verification_failed, waggle.from, job_id, result}
              {:error, reason} -> {:verification_error, waggle.from, job_id, reason}
            end
          end)

          pending = Map.put(state.pending_verifications, task.ref, {waggle.from, job_id})
          %{state | pending_verifications: pending}
      end
    else
      Logger.warning("Could not find job for bee #{waggle.from}, skipping verification")
      # Fallback: try to advance anyway if we can't verify (orphan bee?)
      state = advance_quest(waggle.from, state)
      state
    end
  end

  defp handle_waggle(%{subject: "job_failed"} = waggle, state) do
    Logger.warning("Bee #{waggle.from} reports job failed: #{waggle.body}")
    state = update_in(state.active_bees, &Map.delete(&1, waggle.from))

    job_id = find_job_for_bee(waggle.from)
    if job_id, do: notify_run_job_failed(job_id)

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

          # Re-run validation after rebase before merging
          job_id = find_job_for_bee(waggle.from)

          validation_ok? =
            if job_id do
              case Hive.Validator.validate(waggle.from, %{id: job_id}, cell_id) do
                {:ok, _} -> true
                _ -> false
              end
            else
              true
            end

          if validation_ok? do
            # Re-attempt merge after successful rebase + validation
            case Hive.Merge.merge_back(cell_id) do
              {:ok, strategy} ->
                Logger.info("Post-rebase merge succeeded (#{strategy}) for cell #{cell_id}")
                state

              {:error, reason} ->
                Logger.warning("Post-rebase merge failed for cell #{cell_id}: #{inspect(reason)}")
                reimagine_conflicted_job(cell_id, waggle, state)
            end
          else
            Logger.warning("Post-rebase validation failed for cell #{cell_id}")
            reimagine_conflicted_job(cell_id, waggle, state)
          end

        {:error, reason} ->
          Logger.warning("Conflict resolution failed for cell #{cell_id}: #{inspect(reason)}")
          reimagine_conflicted_job(cell_id, waggle, state)
      end
    else
      # No cell found — reimagine directly by finding the job
      Logger.warning("No cell for bee #{waggle.from}, reimagining job directly")
      reimagine_conflicted_job(nil, waggle, state)
    end
  end

  defp handle_waggle(%{subject: "merge_failed"} = waggle, state) do
    Logger.warning("Merge failed from #{waggle.from}: #{waggle.body}")
    state
  end

  defp handle_waggle(%{subject: "job_merged"} = waggle, state) do
    Logger.info("MergeQueue reports: #{waggle.body}")

    # Extract job_id from body (format: "Job <job_id> merged successfully (tier N)")
    job_id = extract_job_id_from_body(waggle.body)

    if job_id do
      notify_run_job_completed(job_id)

      bee_id =
        case Hive.Jobs.get(job_id) do
          {:ok, job} -> job.bee_id
          _ -> nil
        end

      if bee_id do
        advance_quest(bee_id, state)
      else
        state
      end
    else
      state
    end
  end

  defp handle_waggle(%{subject: "scout_complete"} = waggle, state) do
    # A scout bee finished. Parse its findings and inject them into the parent job.
    case Jason.decode(waggle.body) do
      {:ok, %{"scout_job_id" => scout_job_id, "parent_job_id" => parent_job_id, "output" => output}} ->
        findings = Hive.Scout.parse_findings(output)

        case Hive.Scout.inject_findings(parent_job_id, findings) do
          {:ok, _updated} ->
            Logger.info("Scout findings injected into job #{parent_job_id}")

          {:error, reason} ->
            Logger.warning("Failed to inject scout findings into #{parent_job_id}: #{inspect(reason)}")
        end

        # Unblock dependents (the parent job depends on the scout job)
        Hive.Jobs.unblock_dependents(scout_job_id)

      _ ->
        Logger.warning("Invalid scout_complete waggle body: #{waggle.body}")
    end

    state
  end

  defp handle_waggle(%{subject: "job_retry_created"} = waggle, state) do
    Logger.info("Drone created retry job: #{waggle.body}")
    # The retry job will be picked up by the periodic job spawner
    state
  end

  defp handle_waggle(%{subject: "job_exhausted_retries"} = waggle, state) do
    Logger.warning("Job exhausted retries: #{waggle.body}")
    state
  end

  defp handle_waggle(%{subject: "reimagine_job_created"} = waggle, state) do
    Logger.info("Merge resolver created re-imagine job: #{waggle.body}")
    state
  end

  defp handle_waggle(%{subject: "checkpoint"} = waggle, state) do
    bee_id = waggle.from
    Logger.debug("Checkpoint from bee #{bee_id}: #{waggle.body}")

    checkpoint_data =
      case Jason.decode(waggle.body) do
        {:ok, data} -> data
        _ -> %{}
      end

    last_checkpoint =
      Map.put(state.last_checkpoint, bee_id, %{
        at: DateTime.utc_now(),
        data: checkpoint_data
      })

    # Broadcast progress update
    Phoenix.PubSub.broadcast(
      Hive.PubSub,
      "hive:progress",
      {:bee_checkpoint, bee_id, checkpoint_data}
    )

    %{state | last_checkpoint: last_checkpoint}
  rescue
    _ -> state
  end

  defp handle_waggle(%{subject: "resource_warning"} = waggle, state) do
    bee_id = waggle.from
    Logger.warning("Resource warning from bee #{bee_id}: #{waggle.body}")

    # Broadcast alert
    Phoenix.PubSub.broadcast(
      Hive.PubSub,
      "hive:alerts",
      {:resource_warning, bee_id, waggle.body}
    )

    state
  rescue
    _ -> state
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

  defp handle_waggle(%{subject: "human_approval"} = waggle, state) do
    case Jason.decode(waggle.body) do
      {:ok, %{"action" => "approve", "quest_id" => quest_id} = data} ->
        opts = %{
          approved_by: Map.get(data, "approved_by", waggle.from),
          notes: Map.get(data, "notes")
        }
        Hive.HumanGate.approve(quest_id, opts)
        Hive.Queen.Orchestrator.advance_quest(quest_id)

      {:ok, %{"action" => "reject", "quest_id" => quest_id} = data} ->
        reason = Map.get(data, "reason", "Rejected via waggle")
        Hive.HumanGate.reject(quest_id, reason)
        Hive.Queen.Orchestrator.advance_quest(quest_id)

      _ ->
        Logger.warning("Invalid human_approval waggle body: #{waggle.body}")
    end

    state
  rescue
    _ -> state
  end

  defp handle_waggle(%{subject: "clarification_needed"} = waggle, state) do
    Logger.warning("Clarification request from bee #{waggle.from}: #{waggle.body}")

    Phoenix.PubSub.broadcast(
      Hive.PubSub,
      "hive:alerts",
      {:clarification_needed, waggle.from, waggle.body}
    )

    state
  rescue
    _ -> state
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
        feedback = waggle.body

        # Read persisted retry count from job record (survives Queen restarts)
        attempts =
          case Hive.Jobs.get(job_id) do
            {:ok, job} -> Map.get(job, :retry_count, 0)
            _ -> 0
          end

        if attempts < state.max_retries do
          Logger.info("Retrying job #{job_id} (attempt #{attempts + 1}/#{state.max_retries})")

          # Try intelligent retry first, fall back to simple retry
          case try_intelligent_retry(job_id, feedback, state) do
            {:ok, _} -> state
            {:error, _} -> simple_retry(job_id, feedback, state)
          end
        else
          Logger.warning("Job #{job_id} exhausted #{state.max_retries} retries")
          # Unblock dependents so downstream work isn't permanently stuck
          Hive.Jobs.unblock_dependents(job_id)
          # Handle scout job exhaustion: unblock parent explicitly
          unblock_scout_parent(job_id)
          best_effort_update_quest_status(job_id)
          state
        end

      _ ->
        state
    end
  end

  defp try_intelligent_retry(job_id, feedback, state) do
    case Hive.Intelligence.Retry.retry_with_strategy(job_id, feedback) do
      {:ok, new_job} ->
        case check_quest_budget(new_job.quest_id) do
          :ok ->
            case Hive.Bees.spawn(new_job.id, new_job.comb_id, state.hive_root) do
              {:ok, _bee} -> {:ok, :intelligent_retry}
              error -> error
            end

          {:error, :budget_exceeded} ->
            {:error, :budget_exceeded}
        end

      {:error, reason} ->
        Logger.debug("Intelligent retry unavailable for job #{job_id}: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.debug("Intelligent retry crashed for job #{job_id}: #{inspect(e)}")
      {:error, :intelligent_retry_failed}
  end

  defp simple_retry(job_id, feedback, state) do
    case Hive.Jobs.reset(job_id, feedback) do
      {:ok, job} ->
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
  end

  # -- Private: quest advancement -----------------------------------------------

  defp advance_quest(bee_id, state) do
    with {:ok, bee} <- Hive.Bees.get(bee_id),
         true <- not is_nil(bee[:job_id]),
         {:ok, job} <- Hive.Jobs.get(bee[:job_id]) do
      quest_id = job[:quest_id]
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
    # Check API circuit breaker — don't spawn into an outage
    if Hive.CircuitBreaker.get_state("api:llm") == :open do
      Logger.warning("API circuit breaker is OPEN — skipping job spawning until recovery")
      state
    else
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
        stagger_delay = Hive.Config.Provider.get([:queen, :stagger_delay_ms], 2000)

        jobs_to_spawn = Enum.take(pending_jobs, available_slots)

        # Ensure an active run exists for this quest when spawning jobs
        run = ensure_active_run(quest.id, jobs_to_spawn)

        jobs_to_spawn
        |> Enum.with_index()
        |> Enum.reduce(state, fn {job, idx}, acc ->
          # Stagger: sleep before every spawn except the first
          if idx > 0 and stagger_delay > 0, do: Process.sleep(stagger_delay)

          # Triage before spawning
          {complexity, pipeline} = Hive.Triage.triage(job)
          triage_store_job(job, complexity, pipeline)

          # If complex and no scout exists yet, create one and skip spawning the parent
          if complexity == :complex and Hive.Scout.should_scout?(job) and not scout_exists?(job.id) do
            case Hive.Scout.create_scout_job(job.id, job.comb_id) do
              {:ok, scout_job} ->
                Logger.info("Created scout for complex job #{job.id}, deferring spawn")
                # Spawn the scout job instead
                spawn_single_job(scout_job, acc, run)

              {:error, reason} ->
                Logger.warning("Failed to create scout for job #{job.id}: #{inspect(reason)}, spawning directly")
                spawn_single_job(job, acc, run)
            end
          else
            spawn_single_job(job, acc, run)
          end
        end)
    end
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

  # -- Private: triage helpers -------------------------------------------------

  defp triage_store_job(job, complexity, pipeline) do
    case Hive.Jobs.get(job.id) do
      {:ok, current} ->
        updated = %{current | triage_result: %{complexity: complexity, pipeline: pipeline}}
        Hive.Store.put(:jobs, updated)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp scout_exists?(parent_job_id) do
    Hive.Store.filter(:jobs, fn j ->
      Map.get(j, :scout_for) == parent_job_id and
        j.status not in ["failed", "rejected"]
    end)
    |> Enum.any?()
  rescue
    _ -> false
  end

  defp spawn_single_job(job, state, run) do
    if Hive.Distributed.clustered?() do
      Hive.Distributed.spawn_on_cluster(fn ->
        Hive.Bees.spawn_detached(job.id, job.comb_id, state.hive_root)
      end)
      Logger.info("Dispatched distributed spawn for job #{job.id}")
      state
    else
      case Hive.Bees.spawn_detached(job.id, job.comb_id, state.hive_root) do
        {:ok, bee} ->
          Logger.info("Auto-spawned bee #{bee.id} for job #{job.id} (#{job.title})")
          register_with_run(run, bee.id, job.id)
          state

        {:error, reason} ->
          Logger.warning("Failed to auto-spawn bee for job #{job.id}: #{inspect(reason)}")
          state
      end
    end
  end

  # -- Private: post-review checks --------------------------------------------

  @post_review_interval :timer.minutes(5)

  defp schedule_post_review_check do
    Process.send_after(self(), :check_post_reviews, @post_review_interval)
  end

  defp check_post_reviews do
    reviews = Hive.PostReview.active_reviews()

    Enum.each(reviews, fn review ->
      if Hive.PostReview.expired?(review) do
        Logger.info("Post-review expired for quest #{review.quest_id}, closing")
        Hive.PostReview.close_review(review.quest_id)
      else
        case Hive.PostReview.check_regressions(review.quest_id) do
          {:ok, :clean} ->
            :ok

          {:ok, :regression, findings} ->
            Hive.PostReview.handle_regression(review.quest_id, findings)

          {:error, _reason} ->
            :ok
        end
      end
    end)
  rescue
    e ->
      Logger.warning("Post-review check failed: #{Exception.message(e)}")
  end

  # -- Private: stall detection ------------------------------------------------

  @stall_check_interval :timer.minutes(2)
  @stuck_recovery_interval :timer.minutes(5)
  @phase_advancement_interval :timer.minutes(3)

  defp schedule_stall_check do
    Process.send_after(self(), :check_stalls, @stall_check_interval)
  end

  defp schedule_stuck_recovery do
    Process.send_after(self(), :recover_stuck, @stuck_recovery_interval)
  end

  defp schedule_phase_advancement do
    Process.send_after(self(), :advance_stuck_phases, @phase_advancement_interval)
  end

  defp resume_active_quests(_state) do
    # On startup, find active quests with no running jobs or phase bees and kick them
    active_quests =
      Hive.Store.all(:quests)
      |> Enum.filter(fn q ->
        q[:status] not in [nil, "completed", "failed", "cancelled", "paused"] and
          q[:current_phase] not in [nil, "completed", "failed", "cancelled"]
      end)

    Enum.each(active_quests, fn quest ->
      quest_jobs = Hive.Store.filter(:jobs, fn j ->
        j.quest_id == quest.id and j.status in ["running", "assigned", "pending"]
      end)

      if Enum.empty?(quest_jobs) do
        Logger.info("Resuming stalled quest #{quest.id} (phase: #{quest[:current_phase]}, no active jobs)")
        Hive.Queen.Orchestrator.advance_quest(quest.id)
      end
    end)
  rescue
    e ->
      Logger.warning("Quest resumption failed: #{Exception.message(e)}")
  end

  defp advance_stuck_quest_phases do
    # Periodically call advance_quest for quests in non-terminal phases.
    # This catches cases where a phase bee completed but the waggle was lost.
    phase_statuses = ["research", "requirements", "design", "review", "planning",
                      "implementation", "validation", "awaiting_approval"]

    Hive.Store.all(:quests)
    |> Enum.filter(fn q -> q[:status] in phase_statuses or q[:current_phase] in phase_statuses end)
    |> Enum.each(fn quest ->
      current_phase = quest[:current_phase]

      case Hive.Queen.Orchestrator.advance_quest(quest.id) do
        {:ok, new_phase} ->
          if new_phase != current_phase do
            Logger.info("Periodic phase check advanced quest #{quest.id} to #{new_phase}")
          end

        _ ->
          :ok
      end
    end)
  rescue
    e ->
      Logger.warning("Phase advancement check failed: #{Exception.message(e)}")
  end

  @doc false
  def detect_stalled_bees(state) do
    now = DateTime.utc_now()
    base_stall_seconds = div(state.stall_timeout, 1000)

    working_bees = Hive.Bees.list(status: "working")

    Enum.each(working_bees, fn bee ->
      last_cp = Map.get(state.last_checkpoint, bee.id)

      # Use checkpoint time if available, otherwise use bee's inserted_at
      reference_time =
        if last_cp, do: last_cp.at, else: bee.inserted_at

      seconds_since = DateTime.diff(now, reference_time, :second)

      # Scale stall timeout with job complexity
      stall_seconds = adaptive_stall_timeout(bee, base_stall_seconds)

      if seconds_since > stall_seconds * 2 do
        # Double the stall threshold = hard-fail the bee
        Logger.warning(
          "Hard-stall: bee #{bee.id} unresponsive for #{seconds_since}s, failing job"
        )

        # Kill the worker process if it exists
        case Hive.Bee.Worker.lookup(bee.id) do
          {:ok, pid} -> Process.exit(pid, :kill)
          :error -> :ok
        end

        # Fail the job so retry logic picks it up
        if bee.job_id do
          Hive.Jobs.fail(bee.job_id)
          notify_run_job_failed(bee.job_id)

          waggle = %{
            from: bee.id,
            subject: "stall_timeout",
            body: "Bee stalled for #{seconds_since}s without checkpoint. Auto-failed for retry."
          }
          maybe_retry_job(waggle, state)
        end

        Hive.Store.put(:bees, %{bee | status: "failed"})
      else
        if seconds_since > stall_seconds do
          Logger.warning(
            "Stall detected: bee #{bee.id} has not reported in #{seconds_since}s " <>
              "(threshold: #{stall_seconds}s)"
          )

          Phoenix.PubSub.broadcast(
            Hive.PubSub,
            "hive:alerts",
            {:stall_warning, bee.id, seconds_since}
          )
        end
      end
    end)
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
      if quest[:status] in ["active", "pending", "planning", "research", "implementation", "awaiting_approval"] do
        # Check for deadlocks before spawning
        case Hive.Resilience.detect_deadlock(quest.id) do
          {:error, {:deadlock, cycles}} ->
            Logger.warning("Deadlock in quest #{quest.id}, auto-resolving")
            Hive.Resilience.resolve_deadlock(quest.id, cycles)

          _ ->
            :ok
        end

        # Attach jobs to quest (they're stored separately)
        quest_jobs = Enum.filter(all_jobs, fn j -> j[:quest_id] == quest[:id] end)
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

      try do
        handle_waggle(waggle, acc)
      rescue
        e ->
          Logger.warning("Failed to process recovered waggle #{waggle.id} (#{waggle.subject}): #{Exception.message(e)}")
          acc
      end
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

  defp find_job_for_bee(bee_id) do
    case Hive.Bees.get(bee_id) do
      {:ok, bee} -> bee.job_id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp extract_job_id_from_body(body) when is_binary(body) do
    case Regex.run(~r/Job ([\w-]+)/, body) do
      [_, job_id] -> job_id
      _ -> nil
    end
  end

  defp extract_job_id_from_body(_), do: nil

  defp reimagine_conflicted_job(cell_id, waggle, state) do
    job_id = find_job_for_bee(waggle.from)

    if job_id do
      Logger.info("Reimagining conflicted job #{job_id} (cell #{inspect(cell_id)})")
      Hive.Jobs.fail(job_id)

      cell_info = if cell_id, do: "on cell #{cell_id}", else: "no cell"

      conflict_waggle = %{
        from: waggle.from,
        subject: "merge_conflict",
        body: "Merge conflict #{cell_info}: #{waggle.body}. " <>
              "Redo the work avoiding conflicting file regions."
      }

      maybe_retry_job(conflict_waggle, state)
    else
      Logger.warning("Could not reimagine: no job found for bee #{waggle.from}")
      state
    end
  rescue
    e ->
      Logger.warning("Reimagine failed for cell #{inspect(cell_id)}: #{Exception.message(e)}")
      state
  end

  # Scale stall timeout based on job complexity:
  # simple = 1x (10 min default), moderate = 2x (20 min), complex = 4x (40 min)
  defp adaptive_stall_timeout(bee, base_seconds) do
    multiplier =
      case bee.job_id do
        nil -> 1
        job_id ->
          case Hive.Jobs.get(job_id) do
            {:ok, job} ->
              case Map.get(job, :triage_result) do
                %{complexity: :complex} -> 4
                %{complexity: :moderate} -> 2
                _ ->
                  # Also check string complexity from classifier
                  case Map.get(job, :complexity) do
                    c when c in ["high", "critical"] -> 4
                    "moderate" -> 2
                    _ -> 1
                  end
              end

            _ -> 1
          end
      end

    base_seconds * multiplier
  rescue
    _ -> base_seconds
  end

  defp unblock_scout_parent(job_id) do
    case Hive.Jobs.get(job_id) do
      {:ok, %{scout: true, scout_for: parent_id}} when is_binary(parent_id) ->
        Logger.info("Scout job #{job_id} exhausted retries, unblocking parent #{parent_id}")
        Hive.Jobs.unblock_dependents(job_id)

      _ ->
        :ok
    end
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

  # -- Private: run management ------------------------------------------------

  defp ensure_active_run(quest_id, jobs_to_spawn) do
    case Hive.Run.active_for_quest(quest_id) do
      nil ->
        job_ids = Enum.map(jobs_to_spawn, & &1.id)
        {:ok, run} = Hive.Run.create(quest_id, job_ids: job_ids)
        Logger.info("Created run #{run.id} for quest #{quest_id} with #{length(job_ids)} jobs")
        run

      run ->
        # Add any new jobs that aren't already tracked
        Enum.each(jobs_to_spawn, fn job ->
          unless job.id in run.job_ids do
            Hive.Run.add_job(run.id, job.id)
          end
        end)

        run
    end
  rescue
    e ->
      Logger.warning("Failed to ensure active run for quest #{quest_id}: #{inspect(e)}")
      nil
  end

  defp register_with_run(nil, _bee_id, _job_id), do: :ok

  defp register_with_run(run, bee_id, job_id) do
    Hive.Run.add_bee(run.id, bee_id)

    unless job_id in run.job_ids do
      Hive.Run.add_job(run.id, job_id)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp notify_run_job_completed(job_id) do
    quest_id = job_quest_id(job_id)

    if quest_id do
      case Hive.Run.active_for_quest(quest_id) do
        nil ->
          :ok

        run ->
          case Hive.Run.job_completed(run.id, job_id) do
            {:ok, _run, :run_complete} ->
              Logger.info("Run #{run.id} complete for quest #{quest_id}")

            {:ok, _run} ->
              :ok

            {:error, _} ->
              :ok
          end
      end
    end
  rescue
    _ -> :ok
  end

  defp notify_run_job_failed(job_id) do
    quest_id = job_quest_id(job_id)

    if quest_id do
      case Hive.Run.active_for_quest(quest_id) do
        nil ->
          :ok

        run ->
          case Hive.Run.job_failed(run.id, job_id) do
            {:ok, _run, :run_complete} ->
              Logger.info("Run #{run.id} complete (with failures) for quest #{quest_id}")

            {:ok, _run} ->
              :ok

            {:error, _} ->
              :ok
          end
      end
    end
  rescue
    _ -> :ok
  end

  defp job_quest_id(job_id) do
    case Hive.Jobs.get(job_id) do
      {:ok, job} -> job[:quest_id]
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
