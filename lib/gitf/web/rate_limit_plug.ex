defmodule GiTF.Web.RateLimitPlug do
  @moduledoc """
  Simple per-IP token-bucket rate limit plug using ETS counters with
  time-windowed buckets. Lightweight, no deps.

  Options:
    * `:max_requests` — max requests per window (default 60)
    * `:window_seconds` — window size in seconds (default 60)
    * `:bucket` — atom identifier for separate counter namespaces (default :default)
  """

  @behaviour Plug
  import Plug.Conn

  @table __MODULE__

  @impl true
  def init(opts) do
    ensure_table()

    %{
      max: Keyword.get(opts, :max_requests, 60),
      window: Keyword.get(opts, :window_seconds, 60),
      bucket: Keyword.get(opts, :bucket, :default)
    }
  end

  @impl true
  def call(conn, %{max: max, window: window, bucket: bucket}) do
    ensure_table()
    now = System.system_time(:second)
    window_start = div(now, window) * window
    ip_key = ip_to_key(conn.remote_ip)
    key = {bucket, ip_key, window_start}

    count =
      try do
        :ets.update_counter(@table, key, {2, 1}, {key, 0})
      rescue
        ArgumentError ->
          ensure_table()
          :ets.update_counter(@table, key, {2, 1}, {key, 0})
      end

    if count > max do
      retry_after = window_start + window - now

      conn
      |> put_resp_header("retry-after", Integer.to_string(max(retry_after, 1)))
      |> put_resp_content_type("application/json")
      |> send_resp(429, ~s({"error":"rate limit exceeded"}))
      |> halt()
    else
      conn
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp ip_to_key(ip) when is_tuple(ip), do: :erlang.tuple_to_list(ip)
  defp ip_to_key(other), do: other
end
