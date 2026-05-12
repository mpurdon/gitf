defmodule GiTF.Outcomes.Tracker do
  @moduledoc """
  Periodically polls GitHub for the state of tracked PRs and categorizes
  each outcome via `GiTF.Outcomes.Analyzer`.

  Mirrors `GiTF.Major.Janitor`'s pattern
  (`lib/gitf/major/janitor.ex:42,72-77`): a GenServer under
  `GiTF.Core.Supervisor` that schedules itself via `Process.send_after`.

  The tick interval comes from
  `Application.get_env(:gitf, :timeouts)[:outcome_tracking_interval_ms]`
  (default 5 min). On each tick we:

    1. Short-circuit when `:outcomes_enabled` is false.
    2. Pull the open outcomes where `next_poll_at <= now`.
    3. Resolve the sector's repo path (required for `gh` calls).
    4. Call `GitHub.CLI.pr_details/2`, update the record, re-categorize.
    5. Stop tracking when the category is terminal or >72h has elapsed.

  Polling decay (based on `first_tracked_at` age):

    * `<1h`   →  5 min next poll
    * `1–6h`  → 15 min
    * `6–24h` → 60 min
    * `24–72h`→  4 h
    * `>72h`  → stop tracking, mark stale

  A permanent `gh` error (404, auth) stops tracking with a reason. A
  transient error (network, 5xx) leaves the record in place and schedules
  the next poll without advancing `poll_count`.
  """

  use GenServer
  require Logger

  alias GiTF.Outcomes
  alias GiTF.Outcomes.Analyzer
  alias GiTF.GitHub.CLI

  @name __MODULE__
  @default_interval_ms 5 * 60 * 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Forces an immediate poll pass. Intended for tests and operator nudges."
  @spec tick() :: :ok
  def tick, do: GenServer.cast(@name, :tick)

  # -- GenServer callbacks ---------------------------------------------------

  @impl true
  def init(_opts) do
    Logger.debug("Outcomes.Tracker initialized (enabled=#{Outcomes.enabled?()})")
    schedule_next()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    safe_run(&do_tick/0, "outcome tracker tick")
    schedule_next()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Outcomes.Tracker received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_cast(:tick, state) do
    safe_run(&do_tick/0, "outcome tracker forced tick")
    {:noreply, state}
  end

  # -- Internal: polling loop ------------------------------------------------

  @poll_concurrency 8
  @poll_stream_timeout_ms 20_000

  # Fields that drive categorization or refinement. If none of these
  # changed, the only delta is bookkeeping and isn't worth a disk write.
  @compared_fields [
    :pr_state,
    :pr_merged_at,
    :pr_closed_at,
    :reviews,
    :changes_requested_count,
    :revert_detected,
    :outcome_category
  ]

  defp do_tick do
    if Outcomes.enabled?() do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Outcomes.list_open()
      |> Enum.filter(&due?(&1, now))
      |> Task.async_stream(
        fn outcome -> safe_run(fn -> poll_one(outcome, now) end, "poll outcome #{outcome.id}") end,
        max_concurrency: @poll_concurrency,
        timeout: @poll_stream_timeout_ms,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Stream.run()
    end
  end

  defp due?(%{next_poll_at: nil}, _now), do: true

  defp due?(%{next_poll_at: %DateTime{} = t}, now) do
    DateTime.compare(t, now) != :gt
  end

  defp due?(_, _), do: true

  defp poll_one(outcome, now) do
    # Force-stop if we've been tracking past the stale window.
    if Analyzer.stale?(outcome, now) do
      Outcomes.stop_tracking(outcome.id, "72h expired")
    else
      case Outcomes.repo_path_for(outcome) do
        {:ok, repo_path} -> poll_with_repo(outcome, repo_path, now)
        {:error, reason} -> Outcomes.stop_tracking(outcome.id, "no repo_path: #{inspect(reason)}")
      end
    end
  end

  defp poll_with_repo(outcome, repo_path, now) do
    case CLI.pr_details(repo_path, outcome.pr_url) do
      {:ok, details} ->
        merged = flag_revert?(outcome, details)
        updated = apply_details(outcome, details, merged, now)
        category = Analyzer.categorize(updated, now)
        updated = Map.put(updated, :outcome_category, category)
        terminal? = Outcomes.terminal?(category)
        nothing_changed? = not terminal? and content_unchanged?(outcome, updated)

        if nothing_changed? do
          # Skip the Archive write when the only deltas would be
          # last_polled_at / next_poll_at / poll_count. Saves disk I/O on
          # steady-state PRs polled for weeks.
          emit_telemetry(outcome, category, :unchanged)
        else
          # Rebase deltas onto `current` inside the closure so a concurrent
          # writer (e.g. Alerts.downgrade_to_broke_main on a merged_clean
          # outcome) does not get silently clobbered by our pre-captured
          # snapshot.
          delta = Map.take(updated, @compared_fields ++ [:last_polled_at, :poll_count])

          {:ok, stored} =
            Outcomes.update(outcome.id, fn current ->
              merged = Map.merge(current, delta)

              if terminal? do
                Map.merge(merged, %{tracking_stopped: true, stopped_reason: "terminal"})
              else
                Map.put(merged, :next_poll_at, next_poll_at(merged, now))
              end
            end)

          emit_telemetry(stored, category, :ok)

          if terminal? and not Outcomes.terminal?(outcome.outcome_category) do
            fire_terminal_feedback(stored)
          end
        end

      {:error, :permanent} ->
        Outcomes.stop_tracking(outcome.id, "gh permanent error")

      {:error, reason} when reason in [:transient, :timeout] ->
        Outcomes.update(outcome.id, fn o ->
          Map.merge(o, %{
            last_polled_at: now,
            next_poll_at: next_poll_at(o, now)
          })
        end)

        emit_telemetry(outcome, outcome.outcome_category, {:error, reason})
    end
  end

  defp content_unchanged?(old, new) do
    Enum.all?(@compared_fields, fn f -> Map.get(old, f) == Map.get(new, f) end)
  end

  defp apply_details(outcome, details, revert_flag, now) do
    reviews = details.reviews
    changes_requested = Enum.count(reviews, fn r -> Map.get(r, :state) == "CHANGES_REQUESTED" end)

    Map.merge(outcome, %{
      pr_state: normalize_state(details.state, details.merged),
      pr_merged_at: Outcomes.parse_iso8601(details.merged_at) || outcome.pr_merged_at,
      pr_closed_at: Outcomes.parse_iso8601(details.closed_at) || outcome.pr_closed_at,
      reviews: reviews,
      changes_requested_count: changes_requested,
      revert_detected: revert_flag,
      last_polled_at: now,
      poll_count: (outcome.poll_count || 0) + 1
    })
  end

  # Revert detection is stubbed — the Rollback module tracks auto_merge
  # reverts via the sync artifact, but PR-branch reverts require a
  # separate signal (future work). For now we preserve any existing flag.
  defp flag_revert?(outcome, _details), do: Map.get(outcome, :revert_detected, false)

  defp normalize_state(nil, true), do: "merged"
  defp normalize_state(nil, _), do: nil
  defp normalize_state(_state, true), do: "merged"
  defp normalize_state(state, _merged?) when is_binary(state), do: String.downcase(state)

  # Polling decay schedule. Returns an absolute `DateTime` for next poll.
  defp next_poll_at(outcome, now) do
    age =
      case outcome.first_tracked_at do
        %DateTime{} = t -> max(DateTime.diff(now, t, :second), 0)
        _ -> 0
      end

    DateTime.add(now, next_poll_seconds(age), :second)
  end

  @doc """
  Exposed for tests — returns the next poll wait (seconds) for a given
  outcome age. Pure.
  """
  @spec next_poll_seconds(non_neg_integer()) :: non_neg_integer()
  def next_poll_seconds(age_seconds) do
    cond do
      age_seconds < 1 * 3600 -> 5 * 60
      age_seconds < 6 * 3600 -> 15 * 60
      age_seconds < 24 * 3600 -> 60 * 60
      age_seconds < 72 * 3600 -> 4 * 3600
      true -> 24 * 3600
    end
  end

  # Terminal-transition side effects: skill refinement, Trust cache
  # invalidation, SectorProfile invalidation. All wrapped so a failure in
  # one doesn't stop the others.
  defp fire_terminal_feedback(outcome) do
    mission = GiTF.Archive.get(:missions, outcome.mission_id)

    if mission do
      # Refiner is LLM-backed; run off the poll stream slot so a slow
      # refiner call does not stall the Task.async_stream worker.
      Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
        GiTF.Skills.Refinement.refine_after_merge(mission, outcome)
      end)

      safe_run(fn -> GiTF.Trust.invalidate_merge_cache(mission) end, "invalidate_merge_cache")

      case Map.get(mission, :sector_id) do
        sid when is_binary(sid) ->
          safe_run(fn -> GiTF.Intel.SectorProfile.invalidate(sid) end, "SectorProfile.invalidate")

          # Rate-drop check scans every terminal outcome for the sector;
          # off the poll-stream slot so a large history doesn't serialize.
          Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
            GiTF.Outcomes.Alerts.maybe_alert_on_rate_drop(sid)
          end)

        _ ->
          :ok
      end

      # Post-merge CI status check runs async: its extra gh call must not
      # serialize against the next outcome's poll on this tick.
      if outcome.outcome_category == :merged_clean do
        Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
          GiTF.Outcomes.Alerts.maybe_downgrade_on_ci_red(outcome)
        end)

        # Knowledge.Compile distils entity pages from the merged
        # mission into the sector's wiki. Self-gated; off the poll
        # stream because the LLM call is slow.
        Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
          GiTF.Knowledge.Compile.compile_after_merge(mission, outcome)
        end)
      end
    end
  end

  defp emit_telemetry(outcome, category, status) do
    GiTF.Telemetry.emit([:gitf, :outcomes, :poll], %{}, %{
      outcome_id: outcome.id,
      mission_id: outcome.mission_id,
      category: category,
      status: status
    })
  rescue
    e -> Logger.debug("Outcomes.Tracker telemetry emit failed: #{Exception.message(e)}")
  end

  defp schedule_next do
    interval =
      Application.get_env(:gitf, :timeouts, [])[:outcome_tracking_interval_ms] ||
        @default_interval_ms

    Process.send_after(self(), :tick, interval)
  end

  defp safe_run(fun, label) do
    fun.()
  rescue
    e ->
      Logger.warning("Outcomes.Tracker #{label} failed: #{Exception.message(e)}")
      :error
  end
end
