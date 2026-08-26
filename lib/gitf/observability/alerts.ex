defmodule GiTF.Observability.Alerts do
  @moduledoc """
  Alert system for production monitoring.
  Checks conditions and sends notifications.

  ## Deduplication

  Identical alerts (same type + message) are suppressed for a configurable
  window (default 5 minutes) via an ETS-backed cache. This prevents
  100 simultaneous failures from producing 100 identical webhook calls.

  ## Severity Routing

  Each alert type has an assigned severity (`:critical`, `:high`, `:medium`,
  `:low`). Only alerts at or above the configured minimum severity are
  dispatched to the webhook; all alerts are logged regardless.
  """

  require Logger
  alias GiTF.Archive

  @dedup_table :gitf_alert_dedup
  @dedup_window_seconds 300

  @alert_rules [
    # 30 minutes
    {:quest_stuck, 30 * 60},
    # Below 70%
    {:quality_drop, 70},
    # 2x average
    {:cost_spike, 2.0},
    # 30%
    {:failure_rate_high, 0.3},
    # Failed in last 5 mins
    {:validation_failed, 5 * 60}
  ]

  @severity_map %{
    budget_paused: :critical,
    budget_auto_failed: :critical,
    # A pending approval blocks the mission until a human acts — the single
    # most important thing to push to the operator's phone.
    approval_requested: :critical,
    # The factory stopped or is about to destroy/skip work without a human —
    # for unattended operation these must always reach the operator.
    factory_paused: :critical,
    approval_escalation_failed: :critical,
    quest_failed: :high,
    approval_timed_out: :high,
    approval_timeout_critical: :high,
    # Validation and re-validation disagreed — auto-approve is withheld and
    # the mission blocks on a human, so this must reach the operator.
    approval_revalidation_disagreement: :high,
    # Toolchain/probe broke under validation — code was never judged; fix
    # attempts are held but rounds burn tokens until it clears.
    validation_infra_failure: :high,
    budget_blocked: :high,
    budget_warning: :medium,
    clarification_needed: :high,
    outcome_rate_drop: :high,
    zombie_detected: :high,
    retries_exhausted: :high,
    revert_push_failed: :critical,
    sandbox_broken: :critical,
    github_auth_broken: :high,
    workflow_phase_drift: :critical,
    sync_conflict_theirs: :high,
    sync_retry: :medium,
    security_advisory: :medium,
    # Recurring infrastructure cost changed shape — high because it is a
    # standing bill increase nobody explicitly approved yet.
    infra_cost_changed: :high,
    quest_timeout: :high,
    budget_exceeded: :high,
    quest_exhausted: :high,
    failure_rate_high: :high,
    validation_failed: :high,
    cost_spike: :high,
    ghost_stalled: :high,
    ghost_hard_stalled: :high,
    quest_stuck: :medium,
    quality_drop: :medium,
    budget_escalated: :low,
    # Good-news / informational types: kept below the webhook floor on
    # purpose, mapped explicitly so the coverage test knows it's a decision.
    quest_completed: :low,
    clarification_auto_resolved: :low
  }

  @severity_order %{critical: 0, high: 1, medium: 2, low: 3}

  @doc """
  Returns the severity for a given alert type.

  Unknown types default to :high, not :low: an alert someone bothered to
  emit but forgot to map must fail LOUD — the :low default silently dropped
  mission-failure and budget alerts below the webhook floor for months.
  """
  @spec severity(atom()) :: :critical | :high | :medium | :low
  def severity(type), do: Map.get(@severity_map, type, :high)

  @doc "Check all alert rules and return triggered alerts"
  @spec check_alerts(keyword()) :: [{atom(), String.t()}]
  def check_alerts(opts \\ []) do
    data = %{
      ops: opts[:ops] || Archive.all(:ops),
      missions: opts[:missions] || Archive.all(:missions),
      costs: opts[:costs] || Archive.all(:costs)
    }

    Enum.flat_map(@alert_rules, fn {rule, threshold} ->
      case check_rule(rule, threshold, data) do
        {:alert, message} -> [{rule, message}]
        :ok -> []
      end
    end)
  end

  @doc """
  Send alert notifications with dedup and severity routing.

  Duplicate alerts (same type + message) within the dedup window are
  suppressed. Alerts below the configured minimum webhook severity
  are logged but not sent to the webhook.
  """
  @spec notify([{atom(), String.t()}], atom()) :: :ok
  def notify(alerts, channel \\ :auto) do
    Enum.each(alerts, fn {type, message} -> raise_alert(type, message, channel, []) end)
  end

  @doc """
  Dispatch a single alert (log + telemetry + severity-gated webhook), with
  dedup.

  Options:

    * `:dedup_key` — dedup on this value instead of the message text, so
      recurring callers (e.g. the stall check) can keep useful detail like
      elapsed time in the message without defeating suppression.
  """
  @spec dispatch_webhook(atom(), String.t(), keyword()) :: :ok
  def dispatch_webhook(type, message, opts \\ []) do
    raise_alert(type, message, :auto, opts)
  end

  # The one path every alert takes: dedup, record, telemetry (what messaging
  # channels like Telegram subscribe to), log, severity-gated webhook.
  defp raise_alert(type, message, channel, opts) do
    dedup_key = Keyword.get(opts, :dedup_key, message)

    if duplicate?(type, dedup_key) do
      Logger.debug("Alert suppressed (dedup): #{type}")
    else
      record_alert(type, dedup_key)

      GiTF.Telemetry.emit([:gitf, :alert, :raised], %{}, %{
        type: type,
        message: message,
        severity: severity(type)
      })

      send_notification(:log, type, message)

      case channel do
        :auto ->
          if webhook_url() && meets_severity_threshold?(type) do
            Task.start(fn -> send_notification(:webhook, type, message) end)
          end

        other ->
          send_notification(other, type, message)
      end
    end

    :ok
  end

  @doc "Whether this severity should interrupt the operator rather than batch."
  @spec urgent?(atom()) :: boolean()
  def urgent?(severity) when severity in [:critical, :high], do: true
  def urgent?(_), do: false

  @doc """
  Attach a telemetry handler that forwards [:gitf, :alert, :raised] events
  to the webhook. Also initializes the dedup ETS table.
  """
  @spec attach_webhook_handler() :: :ok
  def attach_webhook_handler do
    init_dedup_table()

    :telemetry.attach(
      "gitf-alert-webhook",
      [:gitf, :alert, :raised],
      &__MODULE__.handle_alert_event/4,
      nil
    )
  rescue
    # Handler already attached or telemetry not available
    _ -> :ok
  end

  @doc false
  def handle_alert_event(_event, _measurements, metadata, _config) do
    # Webhook delivery is handled by notify/2 and dispatch_webhook/2 directly.
    # This handler only fires for external telemetry consumers (dashboards, metrics).
    # No webhook dispatch here to avoid double sends.
    _ = metadata
    :ok
  rescue
    _ -> :ok
  end

  defp check_rule(:validation_failed, threshold_seconds, data) do
    recent_failures =
      Enum.filter(data.ops, fn j ->
        j.status == "done" &&
          Map.get(j, :verification_status) == "failed" &&
          j.verified_at &&
          DateTime.diff(DateTime.utc_now(), j.verified_at) < threshold_seconds
      end)

    if length(recent_failures) > 0 do
      msg = Enum.map(recent_failures, &"Job #{&1.id} failed validation") |> Enum.join(", ")
      {:alert, msg}
    else
      :ok
    end
  end

  defp check_rule(:quest_stuck, threshold_seconds, data) do
    stuck =
      Enum.filter(data.missions, fn q ->
        q.status == "active" &&
          GiTF.Clock.awake_elapsed(q.updated_at) > threshold_seconds
      end)

    if length(stuck) > 0 do
      {:alert, "#{length(stuck)} mission(s) stuck for > #{threshold_seconds}s"}
    else
      :ok
    end
  end

  defp check_rule(:quality_drop, threshold, data) do
    recent = Enum.take(data.ops, -10)
    scores = Enum.map(recent, & &1[:quality_score]) |> Enum.reject(&is_nil/1)

    if !Enum.empty?(scores) do
      avg = Enum.sum(scores) / length(scores)

      if avg < threshold,
        do: {:alert, "Quality score dropped to #{Float.round(avg, 1)}"},
        else: :ok
    else
      :ok
    end
  end

  defp check_rule(:cost_spike, multiplier, data) do
    if length(data.costs) < 10 do
      :ok
    else
      recent = Enum.take(data.costs, -5) |> Enum.map(&(&1[:total_cost_usd] || &1[:cost_usd] || 0))

      older =
        Enum.slice(data.costs, -15..-6) |> Enum.map(&(&1[:total_cost_usd] || &1[:cost_usd] || 0))

      recent_avg = Enum.sum(recent) / length(recent)
      older_avg = Enum.sum(older) / length(older)

      if recent_avg > older_avg * multiplier do
        {:alert, "Cost spike: $#{Float.round(recent_avg, 2)} vs $#{Float.round(older_avg, 2)}"}
      else
        :ok
      end
    end
  end

  defp check_rule(:failure_rate_high, threshold, data) do
    recent = Enum.take(data.ops, -20)

    if length(recent) > 0 do
      failed = Enum.count(recent, &(&1.status == "failed"))
      rate = failed / length(recent)
      if rate > threshold, do: {:alert, "Failure rate: #{Float.round(rate * 100, 1)}%"}, else: :ok
    else
      :ok
    end
  end

  @webhook_max_retries 3

  defp send_notification(:log, type, message) do
    Logger.warning("[ALERT] #{type}: #{message}")
  end

  defp send_notification(:webhook, type, message) do
    case webhook_url() do
      nil ->
        Logger.debug("No webhook URL configured, skipping alert: #{type}")

      url ->
        payload = %{
          text: "[GiTF Alert] #{type}: #{message}",
          type: to_string(type),
          message: message,
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        send_webhook_with_retry(url, payload, type, 0)
    end
  end

  defp send_notification(channel, type, message) do
    Logger.warning("[#{channel}] #{type}: #{message}")
  end

  defp send_webhook_with_retry(_url, _payload, type, attempt)
       when attempt >= @webhook_max_retries do
    Logger.warning("Webhook exhausted #{@webhook_max_retries} retries for alert: #{type}")
  end

  defp send_webhook_with_retry(url, payload, type, attempt) do
    case Req.post(url, json: payload, receive_timeout: 5_000) do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.debug("Webhook alert sent: #{type}")

      {:ok, %{status: status}} when status in [429, 500, 502, 503, 504] ->
        delay = min(:timer.seconds(2) * Integer.pow(2, attempt), :timer.seconds(30))

        Logger.warning(
          "Webhook returned #{status} for alert #{type}, retrying in #{div(delay, 1000)}s (attempt #{attempt + 1}/#{@webhook_max_retries})"
        )

        Process.sleep(delay)
        send_webhook_with_retry(url, payload, type, attempt + 1)

      {:ok, %{status: status}} ->
        Logger.warning("Webhook returned #{status} for alert: #{type}")

      {:error, reason} ->
        delay = min(:timer.seconds(1) * Integer.pow(2, attempt), :timer.seconds(15))

        Logger.warning(
          "Webhook failed for alert #{type}: #{inspect(reason)}, retrying in #{div(delay, 1000)}s (attempt #{attempt + 1}/#{@webhook_max_retries})"
        )

        Process.sleep(delay)
        send_webhook_with_retry(url, payload, type, attempt + 1)
    end
  rescue
    _ ->
      Logger.warning("Webhook crashed for alert #{type} (attempt #{attempt + 1})")
  end

  # -- Dedup ----------------------------------------------------------------

  # GC runs at most once per this interval (seconds)
  @dedup_gc_interval 60

  @doc false
  @spec init_dedup_table() :: atom()
  def init_dedup_table do
    :ets.new(@dedup_table, [:set, :public, :named_table])
  rescue
    ArgumentError -> @dedup_table
  end

  defp dedup_table_exists? do
    :ets.whereis(@dedup_table) != :undefined
  end

  defp duplicate?(type, message) do
    if dedup_table_exists?() do
      key = {type, :erlang.phash2(message)}
      now = System.monotonic_time(:second)

      case :ets.lookup(@dedup_table, key) do
        [{^key, ts}] when now - ts < @dedup_window_seconds -> true
        _ -> false
      end
    else
      false
    end
  rescue
    _ -> false
  end

  defp record_alert(type, message) do
    if dedup_table_exists?() do
      key = {type, :erlang.phash2(message)}
      now = System.monotonic_time(:second)
      :ets.insert(@dedup_table, {key, now})
      maybe_gc_dedup(now)
    end
  rescue
    _ -> :ok
  end

  # Rate-limited GC: only prune stale entries every @dedup_gc_interval seconds
  defp maybe_gc_dedup(now) do
    last_gc_key = :__dedup_last_gc

    run_gc? =
      case :ets.lookup(@dedup_table, last_gc_key) do
        [{^last_gc_key, last}] -> now - last >= @dedup_gc_interval
        _ -> true
      end

    if run_gc? do
      :ets.insert(@dedup_table, {last_gc_key, now})
      cutoff = now - @dedup_window_seconds * 2

      :ets.select_delete(@dedup_table, [
        {{:_, :"$1"}, [{:is_integer, :"$1"}, {:<, :"$1", cutoff}], [true]}
      ])
    end
  rescue
    _ -> :ok
  end

  # -- Severity routing ----------------------------------------------------

  defp meets_severity_threshold?(type) do
    alert_sev = @severity_order[severity(type)] || 3
    min_sev = @severity_order[min_webhook_severity()] || 2
    alert_sev <= min_sev
  end

  defp min_webhook_severity do
    case GiTF.Config.Provider.get([:observability, :min_webhook_severity]) do
      s when s in [:critical, :high, :medium, :low] -> s
      s when is_binary(s) -> String.to_existing_atom(s)
      _ -> :medium
    end
  rescue
    _ -> :medium
  end

  defp webhook_url do
    case GiTF.Config.Provider.get([:observability, :webhook_url]) do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
