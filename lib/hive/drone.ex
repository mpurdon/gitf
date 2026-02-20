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
      {:ok, pid} -> GenServer.call(pid, :check_now)
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
      last_results: []
    }

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
    schedule_patrol(state.poll_interval)
    {:noreply, %{state | last_results: results}}
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

  defp check_verifications do
    unverified_jobs = Hive.Verification.jobs_needing_verification()
    
    # Run verification for unverified jobs
    Enum.flat_map(unverified_jobs, fn job ->
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
    failed_validations = Enum.filter(result.validations, &(&1.status == "fail"))
    
    case failed_validations do
      [] -> "Unknown failure"
      [validation | _] -> validation.output || "Validation failed"
    end
  end
end
