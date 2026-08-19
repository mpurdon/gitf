defmodule GiTF.Infra.CostShape do
  @moduledoc """
  Watches the host's BILLED SHAPE — instance type, provisioned volume size —
  and alerts when it changes.

  Pay-as-you-go spend (tokens) already has budgets, velocity caps and
  webhooks. Fixed infrastructure had nothing: on 2026-08-19 the root volume
  went 12GB → 24GB during an incident and the only trace was a line in a
  chat log. Recurring cost must not be able to change silently, whoever
  changes it — an agent mid-incident, a console click, an autoscaling
  action.

  First observation records a baseline; every later observation compares
  against it and raises `:infra_cost_changed` (with the estimated monthly
  delta) when the shape differs. The operator ACKs by accepting the new
  baseline (`accept_current/0`), which is deliberately a separate act from
  the change itself.

  Prices are approximations for alert copy, not billing: they answer "did
  this just get more expensive, roughly how much" — the bill remains the
  source of truth.
  """

  require Logger

  # us-east-1 on-demand, USD. Approximations for alert copy only.
  @gp3_usd_per_gb_month 0.08
  @instance_hourly %{
    "t4g.nano" => 0.0042,
    "t4g.micro" => 0.0084,
    "t4g.small" => 0.0168,
    "t4g.medium" => 0.0336,
    "t4g.large" => 0.0672,
    "t4g.xlarge" => 0.1344,
    "t4g.2xlarge" => 0.2688,
    "t3.medium" => 0.0416,
    "t3.large" => 0.0832,
    "m7g.medium" => 0.0408,
    "m7g.large" => 0.0816,
    "c7g.large" => 0.0725
  }
  @hours_per_month 730

  # Ignore rounding noise; anything a human would notice on a bill alerts.
  @alert_threshold_usd 0.25

  @doc "The host's current billed shape, or nil fields when not on EC2."
  @spec current() :: map()
  def current do
    instance_type = imds("instance-type")
    volume_gb = root_volume_gb()

    %{
      instance_type: instance_type,
      root_volume_gb: volume_gb,
      estimated_monthly_usd: estimate(instance_type, volume_gb)
    }
  end

  @doc """
  Compares the current shape against the recorded baseline.

  Returns `:ok` (unchanged, or baseline just recorded), `:skipped` when the
  shape can't be read (not EC2), or `{:changed, baseline, current, delta}`
  after raising the alert.
  """
  @spec check() :: :ok | :skipped | {:changed, map(), map(), float()}
  def check do
    shape = current()

    if shape.instance_type == nil and shape.root_volume_gb == nil do
      :skipped
    else
      case baseline() do
        nil ->
          write_baseline(shape)
          Logger.info("Infra cost baseline recorded: #{describe(shape)}")
          :ok

        base ->
          delta = (shape.estimated_monthly_usd || 0.0) - (base["estimated_monthly_usd"] || 0.0)

          if shape_changed?(base, shape) and abs(delta) >= @alert_threshold_usd do
            raise_alert(base, shape, delta)
            {:changed, base, shape, delta}
          else
            :ok
          end
      end
    end
  rescue
    e ->
      Logger.warning("Infra cost shape check failed: #{Exception.message(e)}")
      :skipped
  end

  @doc """
  Accepts the current shape as the new baseline — the operator's ACK.

  Separate from the change itself on purpose: a changed shape keeps
  alerting until someone deliberately says "yes, that one is intended".
  """
  @spec accept_current() :: {:ok, map()}
  def accept_current do
    shape = current()
    write_baseline(shape)
    Logger.info("Infra cost baseline accepted: #{describe(shape)}")
    {:ok, shape}
  end

  @doc "The recorded baseline, or nil when none has been written yet."
  @spec baseline() :: map() | nil
  def baseline do
    with {:ok, body} <- File.read(baseline_path()),
         {:ok, json} <- Jason.decode(body) do
      json
    else
      _ -> nil
    end
  end

  @doc false
  def describe(%{instance_type: t, root_volume_gb: gb, estimated_monthly_usd: usd}) do
    "#{t || "?"} + #{gb || "?"}GB root ≈ $#{:erlang.float_to_binary(usd || 0.0, decimals: 2)}/mo"
  end

  # -- private -----------------------------------------------------------------

  defp shape_changed?(base, shape) do
    base["instance_type"] != shape.instance_type or
      base["root_volume_gb"] != shape.root_volume_gb
  end

  defp raise_alert(base, shape, delta) do
    sign = if delta >= 0, do: "+", else: "-"

    message =
      "Host billed shape CHANGED: #{base["instance_type"]}/#{base["root_volume_gb"]}GB → " <>
        "#{shape.instance_type}/#{shape.root_volume_gb}GB — estimated #{sign}$" <>
        "#{:erlang.float_to_binary(abs(delta), decimals: 2)}/month. " <>
        "If intended, accept it: GiTF.Infra.CostShape.accept_current/0"

    Logger.warning("[ALERT] infra_cost_changed: #{message}")

    GiTF.Observability.Alerts.dispatch_webhook(:infra_cost_changed, message,
      dedup_key: "infra_cost:#{shape.instance_type}:#{shape.root_volume_gb}"
    )
  end

  defp estimate(nil, nil), do: nil

  defp estimate(instance_type, volume_gb) do
    compute = (@instance_hourly[instance_type] || 0.0) * @hours_per_month
    storage = (volume_gb || 0) * @gp3_usd_per_gb_month
    Float.round(compute + storage, 2)
  end

  defp baseline_path do
    dir =
      case :persistent_term.get({GiTF.Archive, :data_path}, nil) do
        nil -> Path.join(System.user_home() || "/tmp", ".gitf")
        path -> Path.dirname(path)
      end

    Path.join(dir, "infra_cost_baseline.json")
  end

  defp write_baseline(shape) do
    path = baseline_path()
    File.mkdir_p(Path.dirname(path))

    File.write(
      path,
      Jason.encode!(Map.put(shape, :recorded_at, DateTime.utc_now() |> DateTime.to_iso8601()))
    )
  end

  # IMDSv2: token first, then the metadata key. Any failure means "not on
  # EC2" — a dev laptop must not alert about instance types.
  defp imds(key) do
    with {token, 0} <-
           cmd("curl", [
             "-s",
             "-m",
             "2",
             "-X",
             "PUT",
             "http://169.254.169.254/latest/api/token",
             "-H",
             "X-aws-ec2-metadata-token-ttl-seconds: 60"
           ]),
         true <- String.trim(token) != "",
         {value, 0} <-
           cmd("curl", [
             "-s",
             "-m",
             "2",
             "http://169.254.169.254/latest/meta-data/#{key}",
             "-H",
             "X-aws-ec2-metadata-token: #{String.trim(token)}"
           ]),
         trimmed = String.trim(value),
         true <- trimmed != "" do
      trimmed
    else
      _ -> nil
    end
  end

  # Provisioned size of the device holding "/", in GB. df's filesystem size
  # tracks it once the FS is grown, which is exactly the post-resize state
  # an operator would be billed for.
  defp root_volume_gb do
    case cmd("df", ["-Pk", "/"]) do
      {out, 0} ->
        case out |> String.split("\n", trim: true) |> List.last() |> String.split() do
          [_dev, total_k | _] ->
            case Integer.parse(total_k) do
              # df reports usable space; round to the nearest provisioned GB.
              {kb, _} -> round(kb / 1024 / 1024)
              :error -> nil
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp cmd(bin, args) do
    task = Task.async(fn -> System.cmd(bin, args, stderr_to_stdout: true) end)

    case Task.yield(task, 5_000) || Task.shutdown(task, 1_000) do
      {:ok, result} -> result
      nil -> {"", 1}
    end
  rescue
    _ -> {"", 1}
  end
end
