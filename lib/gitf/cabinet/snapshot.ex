defmodule GiTF.Cabinet.Snapshot do
  @moduledoc """
  Cached health + spend per ministry, refreshed from the factory's OWN
  API while it is awake (the Cabinet holds no mission state — a snapshot
  is a cached answer, and the factory stays authoritative).

  Spend comes from the factory's cost ledger via `/api/v1/costs/summary`
  with the ministry's api key (by env reference). The ledger's retention
  is factory-side (days, not the calendar month), so the value is stored
  as `spend_usd` with `spend_at` — a recent-spend snapshot, deliberately
  NOT pretending to be month-to-date.
  """

  require Logger

  alias GiTF.Cabinet.Registry

  @doc "Refreshes one ministry's snapshot. No-op unless it is running and reachable."
  def refresh(%{id: id} = ministry) do
    with url when is_binary(url) and url != "" <- ministry[:url] || :no_url,
         key when is_binary(key) and key != "" <- api_key(ministry) || :no_api_key,
         {:ok, spend} <- fetch_spend(url, key) do
      health = fetch_health(url)

      Registry.update(id, fn m ->
        Map.merge(m, %{spend_usd: spend, health: health, spend_at: DateTime.utc_now()})
      end)

      :ok
    else
      reason ->
        Logger.debug("Cabinet: snapshot for #{ministry[:slug]} skipped (#{inspect(reason)})")
        {:error, reason}
    end
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
      {:ok, %{status: 200, body: %{"data" => %{"total_cost" => cost}}}} when is_number(cost) ->
        {:ok, cost / 1}

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
