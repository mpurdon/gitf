defmodule GiTF.Runtime.CallMetrics do
  @moduledoc """
  Per-LLM-call latency records — the numbers a provider migration decision
  needs and the factory never kept: how long each call took, at what
  throughput, and whether it hit a cold provider.

  One `:llm_calls` record per completion, keyed by the provider and the
  *routed* model (the one that actually served the request — the circuit
  can reroute away from the requested spec). Cost and token totals already
  live in `:costs`, but an N-iteration agent run books ONE cost record for
  N HTTP calls, so latency cannot ride that collection; it gets its own.

  TTFT is stored honestly: nothing in the factory streams today (the agent
  loop uses non-streaming generate_text, Bedrock uses non-streaming
  /converse, the CLI hides tokens), so `ttft_ms` is nil with
  `streaming: false` until a path streams. A nil beats a round-trip time
  masquerading as first-token time.

  Cold starts are stored as evidence, not verdicts: each record carries
  `gap_ms` since the previous call to the same provider+model on this node.
  `stats/1` classifies a call as cold when the gap exceeded
  #{5 * 60_000}ms AND its duration exceeded 3x that pair's median —
  thresholds can change without re-collecting.
  """

  alias GiTF.Archive

  @gap_table :gitf_llm_last_call
  @cold_gap_ms 5 * 60_000
  @cold_duration_factor 3

  @doc """
  Records one completed (or failed) LLM call. Never raises — a metrics
  write must not fail the call it describes.
  """
  @spec record(map()) :: :ok
  def record(attrs) when is_map(attrs) do
    key = {attrs[:provider], attrs[:model]}
    now_ms = System.monotonic_time(:millisecond)
    gap_ms = gap_and_touch(key, now_ms)

    {:ok, _} =
      Archive.insert(
        :llm_calls,
        attrs
        |> Map.take([
          :provider,
          :model,
          :mode,
          :kind,
          :duration_ms,
          :ttft_ms,
          :streaming,
          :input_tokens,
          :output_tokens,
          :outcome,
          :mission_id
        ])
        |> Map.put(:gap_ms, gap_ms)
        |> Map.put(:recorded_at, DateTime.utc_now())
      )

    :ok
  rescue
    _ -> :ok
  end

  # Milliseconds since the last call to this provider+model on this node,
  # nil for the first call since boot. ETS rather than Archive: this is
  # consulted on every LLM call and only needs node-local recency.
  defp gap_and_touch(key, now_ms) do
    ensure_gap_table()

    gap =
      case :ets.lookup(@gap_table, key) do
        [{^key, last_ms}] -> now_ms - last_ms
        [] -> nil
      end

    :ets.insert(@gap_table, {key, now_ms})
    gap
  end

  defp ensure_gap_table do
    case :ets.whereis(@gap_table) do
      :undefined ->
        :ets.new(@gap_table, [:named_table, :public, :set, write_concurrency: true])

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Per provider+model performance over the window (default 7 days —
  matching the `:costs` retention, since `$ / 1M effective tokens` joins
  against it).

  Each row: sample count, p50/p95 duration, p50 TTFT over streaming calls
  (nil when nothing streamed), mean output tokens/sec, cold-start rate
  over gap-preceded calls, error rate, and — joined from `:costs` —
  usd_per_1m_effective where effective = input + output + 0.1 * cache_read.
  """
  @spec stats(keyword()) :: [map()]
  def stats(opts \\ []) do
    hours = Keyword.get(opts, :hours, 168)
    cutoff = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    calls =
      Archive.filter(:llm_calls, fn c ->
        case c[:recorded_at] do
          %DateTime{} = at -> DateTime.compare(at, cutoff) == :gt
          _ -> false
        end
      end)

    cost_rows = cost_index(cutoff)

    calls
    |> Enum.group_by(fn c -> {c[:provider], c[:model]} end)
    |> Enum.map(fn {{provider, model}, rows} ->
      durations = rows |> Enum.map(& &1[:duration_ms]) |> Enum.filter(&is_number/1) |> Enum.sort()
      p50 = percentile(durations, 0.5)

      ttfts =
        rows
        |> Enum.filter(&(&1[:streaming] == true))
        |> Enum.map(& &1[:ttft_ms])
        |> Enum.filter(&is_number/1)
        |> Enum.sort()

      toks_per_sec =
        rows
        |> Enum.flat_map(fn r ->
          out = r[:output_tokens]
          dur = r[:duration_ms]

          decode_ms =
            if is_number(r[:ttft_ms]) and is_number(dur), do: dur - r[:ttft_ms], else: dur

          if is_number(out) and out > 0 and is_number(decode_ms) and decode_ms > 0,
            do: [out * 1000 / decode_ms],
            else: []
        end)

      gapped = Enum.filter(rows, &(is_number(&1[:gap_ms]) and &1[:gap_ms] > @cold_gap_ms))

      cold =
        Enum.count(gapped, fn r ->
          is_number(r[:duration_ms]) and is_number(p50) and
            r[:duration_ms] > @cold_duration_factor * p50
        end)

      errors = Enum.count(rows, &(&1[:outcome] != :ok and &1[:outcome] != "ok"))

      %{
        provider: provider,
        model: model,
        calls: length(rows),
        p50_duration_ms: p50,
        p95_duration_ms: percentile(durations, 0.95),
        p50_ttft_ms: percentile(ttfts, 0.5),
        streaming_calls: length(ttfts),
        mean_tokens_per_sec: mean(toks_per_sec),
        cold_starts: cold,
        gap_preceded_calls: length(gapped),
        cold_start_rate: if(gapped == [], do: nil, else: Float.round(cold / length(gapped), 3)),
        error_rate: Float.round(errors / length(rows), 3),
        usd_per_1m_effective: Map.get(cost_rows, normalize_model_key(model))
      }
    end)
    |> Enum.sort_by(& &1.calls, :desc)
  end

  # $/1M effective tokens per normalized model, from the :costs collection —
  # the one place dollars are booked. Effective = input + output + 10% of
  # cache reads: a provider that caches well genuinely costs less per
  # useful token, but a cache read is not worth a fresh token.
  defp cost_index(cutoff) do
    Archive.filter(:costs, fn c ->
      case c[:recorded_at] || c[:inserted_at] do
        %DateTime{} = at -> DateTime.compare(at, cutoff) == :gt
        _ -> false
      end
    end)
    |> Enum.group_by(fn c -> normalize_model_key(c[:model]) end)
    |> Map.new(fn {key, rows} ->
      usd = rows |> Enum.map(&(&1[:cost_usd] || 0)) |> Enum.sum()

      effective =
        Enum.reduce(rows, 0, fn r, acc ->
          acc + (r[:input_tokens] || 0) + (r[:output_tokens] || 0) +
            0.1 * (r[:cache_read_tokens] || 0)
        end)

      value = if effective > 0 and usd > 0, do: Float.round(usd / effective * 1_000_000, 3)
      {key, value}
    end)
  end

  defp normalize_model_key(model) do
    GiTF.Runtime.ModelResolver.normalize_key(to_string(model || "unknown"))
  rescue
    _ -> "unknown"
  end

  @doc false
  # Nearest-rank on a pre-sorted list. Public so Ledger's wall-clock stats
  # do not grow a byte-identical private twin (the MCP handler already had).
  def percentile([], _p), do: nil

  def percentile(sorted, p) do
    idx = min(length(sorted) - 1, max(0, round(p * (length(sorted) - 1))))
    Enum.at(sorted, idx)
  end

  defp mean([]), do: nil
  defp mean(list), do: Float.round(Enum.sum(list) / length(list), 1)
end
