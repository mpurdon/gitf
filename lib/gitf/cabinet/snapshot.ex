defmodule GiTF.Cabinet.Snapshot do
  @moduledoc """
  Cached health + spend per ministry, refreshed from the factory's OWN
  API while it is awake (the Cabinet holds no mission state — a snapshot
  is a cached answer, and the factory stays authoritative).

  Spend comes from the factory's cost ledger via `/api/v1/costs/summary`
  with the ministry's api key (by env reference): `spend_usd` is the
  ledger's total (bounded by its retention — days, not the month), and
  `spend_month_usd` is the factory's month-to-date, which the Gate's cost
  cap reads. The month figure only ratchets UP within a month here: the
  factory's prune sweep can make its own month-to-date drop, and a cap
  that un-trips because old records were pruned is no cap.
  """

  require Logger

  alias GiTF.Cabinet.Registry

  @doc "Refreshes one ministry's snapshot. No-op unless it is running and reachable."
  def refresh(%{id: id} = ministry) do
    with url when is_binary(url) and url != "" <- ministry[:url] || :no_url,
         key when is_binary(key) and key != "" <- api_key(ministry) || :no_api_key,
         {:ok, spend, month_spend} <- fetch_spend(url, key) do
      health = fetch_health(url)
      Registry.update(id, &(&1 |> merge_spend(spend, month_spend) |> Map.put(:health, health)))
      :ok
    else
      reason ->
        Logger.debug("Cabinet: snapshot for #{ministry[:slug]} skipped (#{inspect(reason)})")
        {:error, reason}
    end
  end

  @doc false
  def merge_spend(ministry, spend, month_spend, today \\ Date.utc_today()) do
    month = Date.beginning_of_month(today)
    carried = if ministry[:spend_month] == month, do: ministry[:spend_month_usd] || 0.0, else: 0.0

    Map.merge(ministry, %{
      spend_usd: spend,
      spend_month_usd: max(carried, month_spend || 0.0),
      spend_month: month,
      spend_at: DateTime.utc_now()
    })
  end

  defp api_key(%{api_key_env: env}) when is_binary(env) and env != "", do: System.get_env(env)
  defp api_key(_), do: nil

  defp fetch_spend(url, key) do
    case Req.get(
           url: String.trim_trailing(url, "/") <> "/api/v1/costs/summary",
           headers: [{"x-api-key", key}],
           retry: false,
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: %{"data" => %{"total_cost" => cost} = data}}}
      when is_number(cost) ->
        # month_to_date_cost arrived in 0.65.319; an older factory answers without it.
        month = data["month_to_date_cost"]
        {:ok, cost / 1, if(is_number(month), do: month / 1)}

      {:ok, %{status: status}} ->
        {:error, {:status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_health(url) do
    case Req.get(
           url: String.trim_trailing(url, "/") <> "/api/v1/health",
           retry: false,
           receive_timeout: 8_000
         ) do
      {:ok, %{status: 200, body: %{"data" => %{"status" => status}}}} -> status
      _ -> "unreachable"
    end
  end
end
