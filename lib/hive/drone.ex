defmodule Hive.Drone do
  @moduledoc """
  GenServer that periodically runs health checks (patrols) on the hive.

  The Drone is a background watchdog that polls `Hive.Doctor.run_all/1`
  on a fixed interval and notifies the Queen when issues are found.
  It follows the same polling pattern as `Hive.TranscriptWatcher`.

  ## State

      %{
        poll_interval: pos_integer(),
        auto_fix: boolean(),
        last_results: [Hive.Doctor.check_result()]
      }

  ## Lifecycle

  Started on-demand via `hive drone` or auto-started by the Queen.
  Registered in `Hive.Registry` so there is at most one Drone process.
  """

  use GenServer
  require Logger

  @default_poll_interval :timer.seconds(30)
  @registry_name Hive.Registry
  @registry_key :drone

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  # -- Client API --------------------------------------------------------------

  @doc """
  Starts the Drone GenServer.

  ## Options

    * `:poll_interval` - milliseconds between patrols (default: 30s)
    * `:auto_fix` - whether to auto-fix fixable issues (default: false)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = {:via, Registry, {@registry_name, @registry_key}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the results from the most recent patrol."
  @spec last_results() :: [map()]
  def last_results do
    case lookup() do
      {:ok, pid} -> GenServer.call(pid, :last_results)
      :error -> []
    end
  end

  @doc "Triggers an immediate patrol, returning the results."
  @spec check_now() :: [map()]
  def check_now do
    case lookup() do
      {:ok, pid} -> GenServer.call(pid, :check_now, 30_000)
      :error -> []
    end
  end

  @doc "Looks up the Drone process via the Registry."
  @spec lookup() :: {:ok, pid()} | :error
  def lookup do
    case Registry.lookup(@registry_name, @registry_key) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  # -- GenServer callbacks -----------------------------------------------------

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :poll_interval, @default_poll_interval)
    auto_fix = Keyword.get(opts, :auto_fix, false)
    verify = Keyword.get(opts, :verify, false)

    state = %{
      poll_interval: interval,
      auto_fix: auto_fix,
      verify: verify,
      last_results: [],
      patrol_count: 0
    }

    # Subscribe to PubSub for event-driven verification
    Phoenix.PubSub.subscribe(Hive.PubSub, "drone:review")

    schedule_patrol(interval)
    Logger.info("Drone started (interval: #{interval}ms, auto_fix: #{auto_fix}, verify: #{verify})")
    {:ok, state}
  end

  @impl true
  def handle_call(:last_results, _from, state) do
    {:reply, state.last_results, state}
  end

  def handle_call(:check_now, _from, state) do
    results = run_patrol(state)
    {:reply, results, %{state | last_results: results}}
  end

  @impl true
  def handle_info(:patrol, state) do
    results = run_patrol(state)
    count = state.patrol_count + 1

    # Prune stale worktree metadata every 10 patrols (~5 min)
    if rem(count, 10) == 0 do
      prune_worktrees()
      cleanup_orphan_cells()
      cleanup_if_low_disk()
    end

    # Prune old completed data every 100 patrols (~50 min)
    if rem(count, 100) == 0 do
      prune_old_store_data()
    end

    schedule_patrol(state.poll_interval)
    {:noreply, %{state | last_results: results, patrol_count: count}}
  end

  # -- PubSub-driven verification (event-driven, no polling delay) ------------

  def handle_info({:review_job, job_id, bee_id, cell_id}, state) do
    Logger.info("Drone received review request for job #{job_id} (bee #{bee_id})")

    # Run verification in a fire-and-forget Task to avoid blocking patrols
    Task.start(fn ->
      do_review_job(job_id, bee_id, cell_id)
    end)

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # -- Private helpers ---------------------------------------------------------

  defp schedule_patrol(interval) do
    Process.send_after(self(), :patrol, interval)
  end

  defp run_patrol(state) do
    results = Hive.Doctor.run_all(fix: state.auto_fix)
    budget_results = check_budgets()
    conflict_results = check_merge_conflicts()
    verification_results = check_verifications()
    check_stuck_jobs()
    check_deadlocks()

    queen_results = check_queen_heartbeat()
    all_results = results ++ budget_results ++ conflict_results ++ verification_results ++ queen_results
    issues = Enum.filter(all_results, &(&1.status in [:warn, :error]))

    if issues != [] do
      notify_queen(issues)
    end

    all_results
  rescue
    e ->
      Logger.warning("Drone patrol failed: #{Exception.message(e)}")

      # Alert on patrol failure so it's not silent
      Hive.Telemetry.emit([:hive, :alert, :raised], %{}, %{
        type: :drone_patrol_failed,
        message: "Drone patrol crashed: #{Exception.message(e)}"
      })

      state.last_results
  end

  defp check_budgets do
    Hive.Quests.list()
    |> Enum.filter(&(&1.status == "active"))
    |> Enum.flat_map(fn quest ->
      remaining = Hive.Budget.remaining(quest.id)
      budget = Hive.Budget.budget_for(quest.id)
      pct_used = if budget > 0, do: (1.0 - remaining / budget) * 100, else: 0

      cond do
        remaining < 0 ->
          [
            %{
              name: "budget_check",
              status: :error,
              message: "Quest #{quest.id} exceeded budget ($#{Float.round(-remaining, 2)} over)"
            }
          ]

        pct_used > 80 ->
          [
            %{
              name: "budget_check",
              status: :warn,
              message: "Quest #{quest.id} at #{Float.round(pct_used, 0)}% of budget"
            }
          ]

        true ->
          []
      end
    end)
  rescue
    _ -> []
  end

  defp check_merge_conflicts do
    Hive.Conflict.check_all_active()
    |> Enum.flat_map(fn
      {:ok, _cell_id, :clean} ->
        []

      {:error, cell_id, :conflicts, files} ->
        [
          %{
            name: "merge_conflicts",
            status: :warn,
            message: "Cell #{cell_id} has conflicts in: #{Enum.join(files, ", ")}"
          }
        ]

      _ ->
        []
    end)
  rescue
    _ -> []
  end

  @verification_max_age_seconds 3600

  defp check_verifications do
    unverified_jobs = Hive.Verification.jobs_needing_verification()
    now = DateTime.utc_now()

    # Run verification for unverified jobs
    Enum.flat_map(unverified_jobs, fn job ->
      age = DateTime.diff(now, job.updated_at || job.inserted_at, :second)

      if age > @verification_max_age_seconds do
        # Job stuck in verification queue too long — skip verification, let it merge
        Logger.warning("Drone: job #{job.id} stuck in verification for #{age}s, auto-passing")
        case Hive.Jobs.get(job.id) do
          {:ok, j} -> Hive.Store.put(:jobs, Map.put(j, :verification_status, "passed"))
          _ -> :ok
        end
        []
      else
        case Hive.Verification.verify_job(job.id) do
          {:ok, :pass, _result} ->
            []
          {:ok, :fail, result} ->
            [
              %{
                name: "verification_failed",
                status: :error,
                message: "Job #{job.id} verification failed: #{format_verification_result(result)}"
              }
            ]
          {:error, reason} ->
            [
              %{
                name: "verification_error",
                status: :warn,
                message: "Job #{job.id} verification error: #{inspect(reason)}"
              }
            ]
        end
      end
    end)
  rescue
    _ -> []
  end

  defp check_queen_heartbeat do
    # Only check if there are active quests that need the Queen
    active_quests = Hive.Quests.list() |> Enum.filter(&(&1.status == "active"))

    if active_quests != [] do
      case GenServer.whereis(Hive.Queen) do
        nil ->
          [
            %{
              name: "queen_heartbeat",
              status: :error,
              message: "Queen is not running but #{length(active_quests)} quest(s) are active"
            }
          ]

        pid when is_pid(pid) ->
          try do
            Hive.Queen.status()
            []
          catch
            :exit, {:timeout, _} ->
              [
                %{
                  name: "queen_heartbeat",
                  status: :warn,
                  message: "Queen is unresponsive (timeout)"
                }
              ]

            :exit, _ ->
              [
                %{
                  name: "queen_heartbeat",
                  status: :error,
                  message: "Queen process is dead"
                }
              ]
          end
      end
    else
      []
    end
  rescue
    _ -> []
  end

  defp check_deadlocks do
    Hive.Quests.list()
    |> Enum.filter(&(&1.status in ["active", "pending", "implementation"]))
    |> Enum.each(fn quest ->
      case Hive.Resilience.detect_deadlock(quest.id) do
        {:error, {:deadlock, cycles}} ->
          Logger.warning("Deadlock detected in quest #{quest.id}: #{inspect(cycles)}")
          Hive.Resilience.resolve_deadlock(quest.id, cycles)

        _ ->
          :ok
      end
    end)
  rescue
    _ -> :ok
  end

  defp prune_worktrees do
    Hive.Store.all(:combs)
    |> Enum.each(fn comb ->
      if comb.path && File.dir?(comb.path) do
        Hive.Git.worktree_prune(comb.path)
      end
    end)
  rescue
    _ -> :ok
  end

  @low_disk_threshold_mb 200

  defp cleanup_if_low_disk do
    case Hive.hive_dir() do
      {:ok, hive_root} ->
        task = Task.async(fn -> System.cmd("df", ["-m", hive_root], stderr_to_stdout: true) end)

        df_result = case Task.yield(task, 5_000) || Task.shutdown(task, 1_000) do
          {:ok, cmd_result} -> cmd_result
          nil -> {"", 1}
        end

        case df_result do
          {output, 0} ->
            # Parse df output: last line, 4th column is available MB
            available_mb =
              output
              |> String.split("\n", trim: true)
              |> List.last()
              |> String.split(~r/\s+/)
              |> Enum.at(3)
              |> to_integer_safe()

            if available_mb && available_mb < @low_disk_threshold_mb do
              Logger.warning("Low disk space (#{available_mb}MB), triggering cleanup")

              # 1. Remove completed/stopped cells' worktrees
              Hive.Store.filter(:cells, fn c ->
                c.status in ["completed", "stopped", "removed"]
              end)
              |> Enum.each(fn cell ->
                if cell.worktree_path && File.dir?(cell.worktree_path) do
                  File.rm_rf(cell.worktree_path)
                  Logger.info("Disk cleanup: removed worktree #{cell.worktree_path}")
                end
              end)

              # 2. Prune old store backups (keep only most recent)
              store_path = Path.join([hive_root, ".hive", "store"])
              if File.dir?(store_path) do
                Path.wildcard(Path.join(store_path, "*.bak*"))
                |> Enum.sort()
                |> Enum.drop(-1)
                |> Enum.each(&File.rm/1)
              end
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp to_integer_safe(nil), do: nil
  defp to_integer_safe(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp cleanup_orphan_cells do
    case Hive.Cell.cleanup_orphans() do
      {:ok, 0} -> :ok
      {:ok, count} -> Logger.info("Drone: cleaned up #{count} orphan cells")
    end
  rescue
    _ -> :ok
  end

  @prune_age_hours 48

  defp prune_old_store_data do
    cutoff = DateTime.add(DateTime.utc_now(), -@prune_age_hours * 3600, :second)

    # Prune old read waggles (48h) and very old unread waggles (7d) to prevent unbounded growth
    unread_cutoff = DateTime.add(DateTime.utc_now(), -7 * 24 * 3600, :second)

    pruned_waggles =
      Hive.Store.filter(:waggles, fn w ->
        (w.read == true and DateTime.compare(w.inserted_at, cutoff) == :lt) or
          (w.read != true and DateTime.compare(w.inserted_at, unread_cutoff) == :lt)
      end)

    Enum.each(pruned_waggles, fn w ->
      Hive.Store.delete(:waggles, w.id)
    end)

    # Prune old completed runs
    pruned_runs =
      Hive.Store.filter(:runs, fn r ->
        r.status == "completed" and
          r.completed_at != nil and
          DateTime.compare(r.completed_at, cutoff) == :lt
      end)

    Enum.each(pruned_runs, fn r ->
      Hive.Store.delete(:runs, r.id)
    end)

    # Prune old drone scores (keep last 50 per model)
    prune_old_scores()

    # Prune old events (keep 30 days)
    prune_event_store()

    total = length(pruned_waggles) + length(pruned_runs)
    if total > 0 do
      Logger.info("Store pruned: #{length(pruned_waggles)} waggles, #{length(pruned_runs)} runs")
    end
  rescue
    _ -> :ok
  end

  defp prune_old_scores do
    Hive.Store.all(:drone_scores)
    |> Enum.group_by(& &1.model)
    |> Enum.each(fn {_model, scores} ->
      if length(scores) > 50 do
        scores
        |> Enum.sort_by(& &1.inserted_at, {:asc, DateTime})
        |> Enum.drop(-50)
        |> Enum.each(fn s -> Hive.Store.delete(:drone_scores, s.id) end)
      end
    end)
  rescue
    _ -> :ok
  end

  defp prune_event_store do
    if Code.ensure_loaded?(Hive.EventStore) and function_exported?(Hive.EventStore, :prune, 1) do
      Hive.EventStore.prune(days: 30)
    end
  rescue
    _ -> :ok
  end

  defp check_stuck_jobs do
    Hive.Store.filter(:jobs, fn j -> j.status == "running" end)
    |> Enum.each(fn job ->
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
        Logger.warning("Drone: recovering stuck job #{job.id} (worker dead)")
        Hive.Jobs.fail(job.id)
      end
    end)
  rescue
    _ -> :ok
  end

  defp notify_queen(issues) do
    summary =
      issues
      |> Enum.map(fn i -> "#{i.name}: #{i.message}" end)
      |> Enum.join("; ")

    Hive.Waggle.send("drone", "queen", "health_alert", summary)
  rescue
    _ -> :ok
  end

  defp format_verification_result(result) do
    case Map.get(result, :validations) do
      nil -> Map.get(result, :output, "Unknown failure")
      validations ->
        failed_validations = Enum.filter(validations, &(&1.status == "fail"))
        case failed_validations do
          [] -> "Unknown failure"
          [validation | _] -> validation.output || "Validation failed"
        end
    end
  end

  # -- Verification & improvement pipeline ------------------------------------

  @verification_max_attempts 3

  defp do_review_job(job_id, _bee_id, cell_id) do
    do_review_job_attempt(job_id, cell_id, 1)
  rescue
    e ->
      Logger.error("Drone: review crashed for job #{job_id}: #{Exception.message(e)}")
  end

  defp do_review_job_attempt(job_id, cell_id, attempt) do
    case Hive.Verification.verify_job(job_id) do
      {:ok, :pass, result} ->
        Logger.info("Drone: job #{job_id} passed verification (attempt #{attempt})")
        update_reputation(job_id)
        score_model(job_id, result)

        # Forward to merge queue
        Phoenix.PubSub.broadcast(
          Hive.PubSub,
          "merge:queue",
          {:merge_ready, job_id, cell_id}
        )

      {:ok, :fail, result} ->
        if attempt < @verification_max_attempts do
          Logger.info("Drone: job #{job_id} failed verification (attempt #{attempt}/#{@verification_max_attempts}), retrying")
          Process.sleep(attempt * 2_000)
          do_review_job_attempt(job_id, cell_id, attempt + 1)
        else
          Logger.warning("Drone: job #{job_id} failed verification after #{attempt} attempts")
          update_reputation(job_id)
          score_model(job_id, result)
          reject_and_improve(job_id, cell_id, result)
        end

      {:error, reason} ->
        if attempt < @verification_max_attempts do
          Logger.info("Drone: verification error for job #{job_id} (attempt #{attempt}/#{@verification_max_attempts}): #{inspect(reason)}, retrying")
          Process.sleep(attempt * 3_000)
          do_review_job_attempt(job_id, cell_id, attempt + 1)
        else
          Logger.error("Drone: verification error for job #{job_id} after #{attempt} attempts: #{inspect(reason)}")
          reject_and_improve(job_id, cell_id, %{output: "Verification error: #{inspect(reason)}"})
        end
    end
  end

  defp reject_and_improve(job_id, cell_id, verification_result) do
    # 1. Reject the job
    Hive.Jobs.reject(job_id)

    # 2. Clean up the worktree
    cleanup_cell(cell_id)

    # 3. Analyze the failure
    feedback = extract_feedback(verification_result)
    analysis = analyze_failure(job_id, feedback)

    # 4. Improve agent profile
    improve_from_failure(job_id, analysis)

    # 5. Create retry job if under max retries
    create_retry_if_allowed(job_id, feedback)
  rescue
    e ->
      Logger.error("Drone: reject_and_improve failed for job #{job_id}: #{Exception.message(e)}")
  end

  defp cleanup_cell(nil), do: :ok
  defp cleanup_cell(cell_id) do
    Hive.Cell.remove(cell_id, force: true)
  rescue
    _ -> :ok
  end

  defp extract_feedback(result) do
    Map.get(result, :output) ||
      Map.get(result, "output") ||
      inspect(result) |> String.slice(0, 500)
  end

  defp analyze_failure(job_id, feedback) do
    case Hive.Intelligence.FailureAnalysis.analyze_failure(job_id, feedback) do
      {:ok, analysis} -> analysis
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp improve_from_failure(job_id, analysis) do
    with {:ok, job} <- Hive.Jobs.get(job_id) do
      case Hive.Store.get(:combs, job.comb_id) do
        nil -> :ok
        comb when is_binary(comb.path) -> improve_agent_profile(comb.path, analysis, job)
        _ -> :ok
      end
    end
  rescue
    _ -> :ok
  end

  defp improve_agent_profile(comb_path, analysis, job) do
    alias Hive.AgentProfile.FailureModes

    agents_dir = Path.join(comb_path, ".claude/agents")

    if File.dir?(agents_dir) do
      agents_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.each(fn filename ->
        path = Path.join(agents_dir, filename)
        content = File.read!(path)
        existing_modes = parse_existing_learned_modes(content)

        failure_analysis = build_failure_analysis(analysis, job)
        append_learned_mode(path, content, failure_analysis, existing_modes)
      end)

      Logger.info("Drone: improved agent profile at #{comb_path} with failure lesson")
    end
  rescue
    e -> Logger.debug("Agent profile improvement failed: #{Exception.message(e)}")
  end

  defp build_failure_analysis(nil, job) do
    %{
      type: :unknown,
      root_cause: "Verification failed for: #{job.title}",
      suggestions: ["Ensure changes pass all quality gates before completion"]
    }
  end

  defp build_failure_analysis(analysis, _job) do
    %{
      type: Map.get(analysis, :failure_type, :unknown),
      root_cause: Map.get(analysis, :root_cause, "Unknown"),
      suggestions: Map.get(analysis, :suggestions, [])
    }
  end

  defp append_learned_mode(path, content, failure_analysis, existing_modes) do
    alias Hive.AgentProfile.FailureModes

    case FailureModes.learn_from_failure(failure_analysis, existing_modes) do
      {:ok, mode} ->
        section_header =
          unless String.contains?(content, "## Lessons Learned") do
            "\n\n## Lessons Learned\n\n"
          else
            "\n"
          end

        learned_text = FailureModes.format_learned_mode(mode)
        File.write!(path, content <> section_header <> learned_text)

      :skip ->
        Logger.debug("Drone: skipping duplicate failure mode for #{Path.basename(path)}")
    end
  end

  defp parse_existing_learned_modes(content) do
    # Extract learned mode keys from existing "### LEARNED: KEY (from failure)" lines
    ~r/### LEARNED: (\S+) \(from failure\)/
    |> Regex.scan(content)
    |> Enum.map(fn [_, name] ->
      key = name |> String.downcase() |> String.to_atom()
      %{key: key, name: name, description: "", severity: :high}
    end)
  end

  defp create_retry_if_allowed(job_id, feedback) do
    case Hive.Jobs.get(job_id) do
      {:ok, job} ->
        retry_count = Map.get(job, :retry_count, 0)

        if retry_count < 3 do
          case Hive.Jobs.create_retry(job_id, feedback: feedback) do
            {:ok, retry_job} ->
              Logger.info("Drone: created retry job #{retry_job.id} for #{job_id} (attempt #{retry_count + 1})")
              Hive.Waggle.send("drone", "queen", "job_retry_created",
                "Retry #{retry_job.id} for failed job #{job_id} (attempt #{retry_count + 1})")

            {:error, :max_retries_exceeded} ->
              Logger.warning("Drone: job #{job_id} exhausted retries")
              Hive.Waggle.send("drone", "queen", "job_exhausted_retries",
                "Job #{job_id} exhausted all retries")

            {:error, reason} ->
              Logger.warning("Drone: retry creation failed for #{job_id}: #{inspect(reason)}")
          end
        else
          Logger.warning("Drone: job #{job_id} already at #{retry_count} retries, no more attempts")
          Hive.Waggle.send("drone", "queen", "job_exhausted_retries",
            "Job #{job_id} exhausted #{retry_count} retries")
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp score_model(job_id, verification_result) do
    with {:ok, job} <- Hive.Jobs.get(job_id) do
      score = Hive.Drone.Scoring.score(job, verification_result)
      Hive.Drone.Scoring.record(score)
      Logger.debug("Drone: recorded score for model #{score.model} on job #{job_id}")

      try do
        Hive.AgentIdentity.update_from_score(score.model, score)
      rescue
        e -> Logger.debug("Drone: agent identity update failed: #{Exception.message(e)}")
      end
    end
  rescue
    e ->
      Logger.debug("Drone: scoring failed for job #{job_id}: #{Exception.message(e)}")
      :ok
  end

  defp update_reputation(job_id) do
    Hive.Reputation.update_after_job(job_id)
  rescue
    _ -> :ok
  end
end
