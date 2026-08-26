defmodule GiTF.Eval do
  @moduledoc """
  Golden eval suite runner. Iterates registered scenarios, executes
  each case, aggregates results, formats console + JSON reports.

  Scenarios are listed at compile time in `@scenarios`. Add new ones
  there. There is no auto-discovery — explicit registration keeps the
  set stable across builds and lets `--scenario <name>` filtering work
  reliably.

  ## Usage

      mix gitf.eval                          # all scenarios, console only
      mix gitf.eval --scenario skills_retrieval
      mix gitf.eval --json /tmp/eval.json    # also write JSON report
      mix gitf.eval --model sonnet           # pass through to scenarios

  Returns a structured map describing the run. Mix task wraps that and
  exits non-zero if any case failed (so CI / cron-routines can gate on
  it).
  """

  @scenarios [
    GiTF.Eval.SkillsRetrieval,
    GiTF.Eval.KnowledgeRetrieval
  ]

  @doc "Returns the list of registered scenario modules."
  @spec scenarios() :: [module()]
  def scenarios, do: @scenarios

  @doc """
  Runs the configured scenarios. Options:

    * `:scenario` — only run scenarios whose `name/0` matches
    * `:opts` — keyword list passed through to each scenario's `run/2`
    * `:scenarios` — override the registered scenario list (tests)
  """
  @spec run(keyword()) :: map()
  def run(opts \\ []) do
    filter = Keyword.get(opts, :scenario)
    scenario_opts = Keyword.get(opts, :opts, [])
    pool = Keyword.get(opts, :scenarios, @scenarios)

    selected =
      pool
      |> Enum.filter(fn mod -> is_nil(filter) or mod.name() == filter end)

    started_at = DateTime.utc_now()

    scenario_reports =
      Enum.map(selected, fn mod -> run_scenario(mod, scenario_opts) end)

    elapsed_ms =
      DateTime.diff(DateTime.utc_now(), started_at, :millisecond)

    summary = aggregate(scenario_reports)

    %{
      started_at: started_at,
      elapsed_ms: elapsed_ms,
      scenarios: scenario_reports,
      summary: summary
    }
  end

  @doc "Renders a run report as a multi-line console string."
  @spec format_console(map()) :: String.t()
  def format_console(%{scenarios: scenarios, summary: summary, elapsed_ms: elapsed_ms}) do
    scenario_lines = Enum.map(scenarios, &format_scenario/1)
    summary_line = format_summary(summary, elapsed_ms)

    [scenario_lines, "", summary_line]
    |> List.flatten()
    |> Enum.join("\n")
  end

  # -- Internal --------------------------------------------------------------

  @case_concurrency 4
  @case_timeout_ms 120_000

  defp run_scenario(mod, scenario_opts) do
    started_at = System.monotonic_time(:millisecond)

    case_results =
      mod.cases()
      |> Task.async_stream(
        fn case_map -> run_case(mod, case_map, scenario_opts) end,
        max_concurrency: @case_concurrency,
        timeout: @case_timeout_ms,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.map(fn
        {:ok, result} ->
          result

        {:exit, reason} ->
          %{
            id: "?",
            result: :fail,
            meta: %{reason: "task exited: #{inspect(reason)}"},
            elapsed_ms: 0
          }
      end)

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    %{
      name: mod.name(),
      description: mod.description(),
      cases: case_results,
      elapsed_ms: elapsed_ms,
      counts: tally(case_results)
    }
  end

  defp run_case(mod, case_map, scenario_opts) do
    started_at = System.monotonic_time(:millisecond)

    {result, meta} =
      try do
        case mod.run(case_map, scenario_opts) do
          {:pass, m} -> {:pass, m}
          {:fail, m} -> {:fail, m}
          {:skip, reason} -> {:skip, %{reason: reason}}
          other -> {:fail, %{reason: "scenario returned bad shape: #{inspect(other)}"}}
        end
      rescue
        e -> {:fail, %{reason: "raised: #{Exception.message(e)}"}}
      end

    %{
      id: Map.get(case_map, :id, "anon"),
      result: result,
      meta: meta,
      elapsed_ms: System.monotonic_time(:millisecond) - started_at
    }
  end

  @empty_counts %{pass: 0, fail: 0, skip: 0}

  defp tally(case_results) do
    Enum.reduce(case_results, @empty_counts, fn %{result: r}, acc ->
      Map.update(acc, r, 1, &(&1 + 1))
    end)
  end

  defp aggregate(scenario_reports) do
    Enum.reduce(scenario_reports, @empty_counts, fn %{counts: c}, acc ->
      Map.merge(acc, c, fn _, a, b -> a + b end)
    end)
  end

  defp format_scenario(%{name: name, description: desc, cases: cases, counts: c, elapsed_ms: ms}) do
    header = "▸ #{name} — #{desc}  [#{c.pass}P/#{c.fail}F/#{c.skip}S in #{ms}ms]"

    lines =
      Enum.map(cases, fn %{id: id, result: r, meta: meta, elapsed_ms: ems} ->
        sym =
          case r do
            :pass -> "✓"
            :fail -> "✗"
            :skip -> "·"
          end

        suffix =
          case {r, meta} do
            {:pass, %{rank: rank}} when not is_nil(rank) -> " (rank=#{rank})"
            {:fail, %{reason: reason}} -> " — #{reason}"
            {:skip, %{reason: reason}} -> " — #{reason}"
            _ -> ""
          end

        "    #{sym} #{id} [#{ems}ms]#{suffix}"
      end)

    [header | lines]
  end

  defp format_summary(%{pass: p, fail: f, skip: s}, elapsed_ms) do
    total = p + f + s
    rate = if p + f > 0, do: Float.round(p / (p + f), 3), else: nil
    rate_part = if rate, do: " | pass-rate #{rate}", else: ""
    "Total: #{total} cases — #{p}P / #{f}F / #{s}S in #{elapsed_ms}ms#{rate_part}"
  end
end
