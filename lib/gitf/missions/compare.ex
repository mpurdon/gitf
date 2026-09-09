defmodule GiTF.Missions.Compare do
  @moduledoc """
  Two missions side by side on the metrics an A/B is judged on — the Wire
  success-rate protocol in `specs/WIRE.md` §8, and any other "same goal,
  one thing changed" pair: how each reply was parsed, the validation
  verdicts, fix rounds, wall clock, and cost by phase.

  Pure reads; the numbers come from the mission record, its ops, its
  transitions and the costs table.
  """

  alias GiTF.{Archive, Costs, Missions, Ops}

  @spec compare(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def compare(a_id, b_id) do
    with {:ok, a} <- profile(a_id),
         {:ok, b} <- profile(b_id) do
      {:ok, %{a: a, b: b, delta: delta(a, b)}}
    end
  end

  @doc "One mission's A/B profile."
  @spec profile(String.t()) :: {:ok, map()} | {:error, :not_found}
  def profile(mission_id) do
    case Archive.get(:missions, mission_id) do
      nil ->
        {:error, :not_found}

      mission ->
        ops = Ops.list(mission_id: mission_id)
        costs = Costs.quest_phase_summary(mission_id)
        tally = Map.get(mission, :notation_tally) || %{}

        {:ok,
         %{
           id: mission_id,
           name: mission[:name],
           status: mission[:status],
           wire: Map.get(mission, :wire),
           notation: notation_totals(tally),
           notation_by_phase: tally,
           validation: validation_summary(mission),
           fix_rounds: Enum.count(ops, &is_binary(&1[:fix_of])),
           ops: length(ops),
           failed_ops: Enum.count(ops, &(&1[:status] == "failed")),
           wall_clock_seconds: wall_clock(mission_id),
           cost_usd: costs.total,
           cost_by_phase: costs.by_phase
         }}
    end
  end

  defp notation_totals(tally) do
    Enum.reduce(tally, %{"wire" => 0, "json" => 0, "json_fallback" => 0, "parse_failed" => 0}, fn
      {_phase, counts}, acc when is_map(counts) ->
        Map.merge(acc, counts, fn _k, x, y -> x + y end)

      _, acc ->
        acc
    end)
  end

  defp validation_summary(mission) do
    mission
    |> Missions.live_artifacts("validation")
    |> Enum.map(fn {key, artifact} ->
      met = List.wrap(artifact["requirements_met"])

      %{
        key: key,
        verdict: artifact["overall_verdict"],
        met: Enum.count(met, &(&1["met"] == true)),
        unmet: Enum.count(met, &(&1["met"] == false))
      }
    end)
  end

  defp wall_clock(mission_id) do
    times =
      mission_id
      |> Missions.get_phase_transitions()
      |> Enum.map(& &1.inserted_at)

    case times do
      [] -> nil
      _ -> DateTime.diff(Enum.max(times, DateTime), Enum.min(times, DateTime), :second)
    end
  end

  # b relative to a, for the numbers where a difference means something.
  defp delta(a, b) do
    %{
      cost_usd: round4(b.cost_usd - a.cost_usd),
      cost_pct: pct(a.cost_usd, b.cost_usd),
      wall_clock_seconds: sub(b.wall_clock_seconds, a.wall_clock_seconds),
      fix_rounds: b.fix_rounds - a.fix_rounds,
      parse_failed: b.notation["parse_failed"] - a.notation["parse_failed"],
      json_fallback: b.notation["json_fallback"] - a.notation["json_fallback"],
      tokens_by_phase: tokens_delta(a.cost_by_phase, b.cost_by_phase)
    }
  end

  defp tokens_delta(a, b) do
    (Map.keys(a) ++ Map.keys(b))
    |> Enum.uniq()
    |> Map.new(fn phase ->
      ta = tokens(a[phase])
      tb = tokens(b[phase])
      {phase, %{input: tb.input - ta.input, output: tb.output - ta.output}}
    end)
  end

  defp tokens(nil), do: %{input: 0, output: 0}
  defp tokens(%{input_tokens: i, output_tokens: o}), do: %{input: i, output: o}

  defp sub(nil, _), do: nil
  defp sub(_, nil), do: nil
  defp sub(x, y), do: x - y

  defp pct(a, _b) when a in [nil, 0, 0.0], do: nil
  defp pct(a, b), do: Float.round((b - a) / a * 100, 1)

  defp round4(x), do: Float.round(x * 1.0, 4)
end
