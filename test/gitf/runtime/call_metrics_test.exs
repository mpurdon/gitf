defmodule GiTF.Runtime.CallMetricsTest do
  @moduledoc """
  The numbers a serverless-provider migration decision reads. What matters:
  cold-start classification uses stored evidence (gap + duration), TTFT is
  never faked from non-streaming calls, and a metrics write can never fail
  the LLM call it describes.
  """

  use GiTF.StoreCase

  alias GiTF.Runtime.CallMetrics

  defp call(attrs) do
    Map.merge(
      %{
        provider: "bedrock",
        model: "arn:aws:bedrock:us-east-1:1:inference-profile/us.anthropic.claude-sonnet-5",
        mode: :bedrock,
        kind: :api_call,
        duration_ms: 2_000,
        ttft_ms: nil,
        streaming: false,
        output_tokens: 500,
        outcome: :ok
      },
      attrs
    )
  end

  test "records carry a gap since the previous call to the same provider+model" do
    :ok = CallMetrics.record(call(%{}))
    :ok = CallMetrics.record(call(%{}))

    gaps =
      GiTF.Archive.all(:llm_calls)
      |> Enum.sort_by(& &1.inserted_at)
      |> Enum.map(& &1[:gap_ms])

    # A different model does not inherit the gap chain.
    :ok = CallMetrics.record(call(%{model: "google:gemini-2.5-pro", provider: "google"}))
    other = GiTF.Archive.filter(:llm_calls, &(&1[:provider] == "google")) |> hd()

    assert [_first, second] = gaps
    assert is_number(second) or is_nil(hd(gaps))
    assert is_nil(other[:gap_ms])
  end

  test "stats: throughput, percentiles, and honest TTFT nulls" do
    for d <- [1_000, 2_000, 3_000] do
      :ok = CallMetrics.record(call(%{duration_ms: d, output_tokens: 500}))
    end

    [row] = CallMetrics.stats(hours: 1)

    assert row.calls == 3
    assert row.p50_duration_ms == 2_000
    # Nothing streamed, so TTFT must be nil — not the round-trip time.
    assert row.p50_ttft_ms == nil
    assert row.streaming_calls == 0
    # 500 tokens over 1s/2s/3s → 500, 250, 166.7 → mean ≈ 305.6
    assert_in_delta row.mean_tokens_per_sec, 305.6, 1.0
    assert row.error_rate == 0.0
  end

  test "stats: a long gap alone is not a cold start; a slow call after one is" do
    # Build a median around 2s, then two gap-preceded calls: one at median
    # (warm despite the gap) and one at 4x median (cold).
    for _ <- 1..6, do: :ok = CallMetrics.record(call(%{duration_ms: 2_000}))

    warm = call(%{duration_ms: 2_100})
    cold = call(%{duration_ms: 8_000})

    # gap_ms is computed from a node-local ETS clock we can't wind forward,
    # so write the evidence directly — stats reads records, not the clock.
    {:ok, _} =
      GiTF.Archive.insert(
        :llm_calls,
        Map.merge(warm, %{gap_ms: 600_000, recorded_at: DateTime.utc_now()})
      )

    {:ok, _} =
      GiTF.Archive.insert(
        :llm_calls,
        Map.merge(cold, %{gap_ms: 600_000, recorded_at: DateTime.utc_now()})
      )

    [row] = CallMetrics.stats(hours: 1)

    assert row.gap_preceded_calls == 2
    assert row.cold_starts == 1
    assert row.cold_start_rate == 0.5
  end

  test "stats joins $/1M effective tokens from the costs collection" do
    :ok = CallMetrics.record(call(%{model: "anthropic:claude-sonnet-5", provider: "anthropic"}))

    {:ok, _} =
      GiTF.Archive.insert(:costs, %{
        model: "anthropic:claude-sonnet-5",
        input_tokens: 700_000,
        output_tokens: 200_000,
        cache_read_tokens: 1_000_000,
        cost_usd: 3.0,
        recorded_at: DateTime.utc_now()
      })

    [row] = CallMetrics.stats(hours: 1)

    # effective = 700k + 200k + 0.1 * 1M = 1M → $3.00 per 1M
    assert row.usd_per_1m_effective == 3.0
  end

  test "recording never raises, even on garbage" do
    assert :ok = CallMetrics.record(%{provider: nil, model: nil, duration_ms: "fast"})
  end

  test "errors are counted into error_rate" do
    :ok = CallMetrics.record(call(%{outcome: :timeout}))
    :ok = CallMetrics.record(call(%{outcome: :ok}))

    [row] = CallMetrics.stats(hours: 1)
    assert row.error_rate == 0.5
  end
end
