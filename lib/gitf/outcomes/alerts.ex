defmodule GiTF.Outcomes.Alerts do
  @moduledoc """
  Alerting + validator-calibration metrics on top of the outcome stream.
  The Tracker calls `maybe_alert_on_rate_drop/1` after it marks any
  sector's outcome terminal; this module decides whether a rolling 24h
  window has dipped below the baseline minus N stddev and fires a
  webhook via `GiTF.Observability.Alerts.dispatch_webhook/2`.

  Calibration: for each mission we compare the validator's
  `overall_verdict` (pass/fail) to the real outcome (merged_clean vs any
  negative terminal). The disagreement rate is a direct "how well
  calibrated is the validator" signal — surfaced in outcomes_stats.
  """

  require Logger

  alias GiTF.Archive
  alias GiTF.Missions
  alias GiTF.Observability.Alerts
  alias GiTF.Outcomes

  @window_hours 24

  @doc """
  Compares the rolling 24h merge-success rate for a sector to its
  lifetime baseline; if the 24h window dips below baseline minus
  N × stddev, fires a webhook. N comes from
  `:autonomy_alert_threshold_stddev` (default 2).

  Returns `:ok` always — never raises, never blocks the tracker.
  """
  @spec maybe_alert_on_rate_drop(String.t() | nil) :: :ok
  def maybe_alert_on_rate_drop(nil), do: :ok

  def maybe_alert_on_rate_drop(sector_id) when is_binary(sector_id) do
    outcomes = Outcomes.terminal_outcomes(sector_id)
    recent = recent_window(outcomes, @window_hours)

    # Need enough baseline and recent samples for stddev to be meaningful.
    if length(outcomes) >= 10 and length(recent) >= 3 do
      baseline_rate = success_rate(outcomes)
      recent_rate = success_rate(recent)
      threshold_n = Application.get_env(:gitf, :autonomy_alert_threshold_stddev, 2)
      threshold = max(baseline_rate - threshold_n * sector_stddev(outcomes), 0.0)

      if recent_rate < threshold do
        Alerts.dispatch_webhook(
          :outcome_rate_drop,
          "Sector #{sector_id} 24h merge-success rate #{fmt_pct(recent_rate)} dropped below " <>
            "baseline #{fmt_pct(baseline_rate)} (threshold #{fmt_pct(threshold)}, " <>
            "#{length(recent)}/#{length(outcomes)} recent/total)"
        )
      end
    end

    :ok
  rescue
    e ->
      Logger.warning("Outcomes.Alerts.maybe_alert_on_rate_drop failed: #{Exception.message(e)}")
      :ok
  end

  @doc """
  Validator calibration: fraction of missions where the validator's
  `overall_verdict` agreed with the real outcome. Returns
  `%{accuracy: float, sample_count: n}` or `nil` when there's no signal.
  """
  @spec calibration(String.t() | nil) ::
          %{accuracy: float(), sample_count: non_neg_integer()} | nil
  def calibration(sector_filter \\ nil) do
    pool = Outcomes.terminal_outcomes(sector_filter)

    scored =
      pool
      |> Enum.map(&score_mission_vs_validator/1)
      |> Enum.reject(&is_nil/1)

    case scored do
      [] ->
        nil

      pairs ->
        agreements = Enum.count(pairs, fn {validator, outcome} -> validator == outcome end)

        %{
          accuracy: Float.round(agreements / length(pairs), 3),
          sample_count: length(pairs)
        }
    end
  rescue
    e ->
      Logger.warning("Outcomes.Alerts.calibration failed: #{Exception.message(e)}")
      nil
  end

  @doc """
  Post-merge CI status check — called by the tracker for outcomes that
  hit `:merged_clean` within the last 24h. If the main-branch CI has a
  red run within 4h of the merge, downgrades the outcome to
  `:merged_broke_main`.

  Returns `{:ok, :unchanged | :downgraded}` or `{:error, reason}`.
  """
  @spec maybe_downgrade_on_ci_red(map()) :: {:ok, :unchanged | :downgraded} | {:error, term()}
  def maybe_downgrade_on_ci_red(outcome) do
    with true <- outcome.outcome_category == :merged_clean,
         %DateTime{} = merged_at <- outcome.pr_merged_at,
         true <- DateTime.diff(DateTime.utc_now(), merged_at, :second) <= 24 * 3600,
         {:ok, repo_path} <- Outcomes.repo_path_for(outcome),
         {:ok, ran_red?} <- ci_red_within_window?(repo_path, merged_at, 4 * 3600) do
      if ran_red?, do: downgrade_to_broke_main(outcome), else: {:ok, :unchanged}
    else
      false -> {:ok, :unchanged}
      {:error, _} = err -> err
    end
  rescue
    e ->
      Logger.warning("Outcomes.Alerts.maybe_downgrade_on_ci_red failed: #{Exception.message(e)}")
      {:ok, :unchanged}
  end

  defp downgrade_to_broke_main(outcome) do
    case Outcomes.update(outcome.id, fn o ->
           Map.put(o, :outcome_category, :merged_broke_main)
         end) do
      {:ok, updated} ->
        GiTF.Telemetry.emit([:gitf, :outcomes, :downgraded], %{}, %{
          outcome_id: updated.id,
          sector_id: Map.get(updated, :sector_id),
          new_category: :merged_broke_main
        })

        {:ok, :downgraded}

      {:error, _} = err ->
        err
    end
  end

  # -- Internal --------------------------------------------------------------

  defp recent_window(outcomes, hours) do
    cutoff = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    Enum.filter(outcomes, fn o ->
      case Map.get(o, :updated_at) do
        %DateTime{} = t -> DateTime.compare(t, cutoff) == :gt
        _ -> false
      end
    end)
  end

  defp success_rate([]), do: 0.0

  defp success_rate(outcomes) do
    merged = Enum.count(outcomes, &(&1.outcome_category == :merged_clean))
    merged / length(outcomes)
  end

  # Sample standard deviation of per-outcome merge indicators (1/0). For
  # a Bernoulli variable this is sqrt(p * (1 - p)).
  defp sector_stddev(outcomes) do
    p = success_rate(outcomes)
    :math.sqrt(max(p * (1 - p), 0.0))
  end

  defp fmt_pct(n) when is_number(n), do: "#{round(n * 1000) / 10}%"

  # Pairs validator verdict (`:pass` / `:fail` / nil) with outcome result
  # (`:pass` merged, `:fail` otherwise). nil when no validation artifact.
  defp score_mission_vs_validator(outcome) do
    with mission <- Archive.get(:missions, outcome.mission_id),
         true <- is_map(mission),
         validation <- Missions.get_artifact(mission.id, "validation"),
         true <- is_map(validation),
         verdict when verdict in ["pass", "fail"] <- validation["overall_verdict"] do
      validator = if verdict == "pass", do: :pass, else: :fail

      outcome_result =
        case outcome.outcome_category do
          :merged_clean -> :pass
          _ -> :fail
        end

      {validator, outcome_result}
    else
      _ -> nil
    end
  end

  # Uses `gh run list --branch main --limit 5` to find recent CI runs
  # that completed in the window (merged_at, merged_at + window_secs]. A
  # "failure" conclusion within the window counts as red.
  defp ci_red_within_window?(repo_path, merged_at, window_secs) do
    case GiTF.GitHub.CLI.main_branch_runs(repo_path, 5) do
      {:ok, runs} when is_list(runs) ->
        cutoff = DateTime.add(merged_at, window_secs, :second)

        red? =
          Enum.any?(runs, fn r ->
            case Outcomes.parse_iso8601(Map.get(r, "createdAt")) do
              nil ->
                false

              t ->
                Map.get(r, "conclusion") in ["failure", "timed_out", "cancelled"] and
                  DateTime.compare(t, merged_at) == :gt and
                  DateTime.compare(t, cutoff) != :gt
            end
          end)

        {:ok, red?}

      {:error, _} = err ->
        err
    end
  end
end
