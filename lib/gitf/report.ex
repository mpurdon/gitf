defmodule GiTF.Report do
  @moduledoc """
  Generates mission performance reports from store data and ghost log files.

  Parses stream-json logs to extract token usage and cost, combines with
  op/ghost timing data from the store, and produces a formatted summary.
  """

  alias GiTF.Runtime.StreamParser
  alias GiTF.Archive

  # -- Public API ------------------------------------------------------------

  @doc """
  Generates a full report for a mission.

  Returns `{:ok, report}` where report is a map with:
  - `:mission` - the mission record
  - `:ops` - list of op details with timing and ghost info
  - `:tokens` - aggregate token usage
  - `:cost` - aggregate cost
  - `:timing` - wall clock start/end/duration
  - `:output` - file/line counts from git

  Or `{:error, reason}`.
  """
  @spec generate(String.t()) :: {:ok, map()} | {:error, term()}
  def generate(mission_id) do
    with {:ok, mission} <- GiTF.Missions.get(mission_id) do
      gitf_root = gitf_root()
      ops = enrich_jobs(mission.ops, gitf_root)
      tokens = aggregate_tokens(ops)
      timing = compute_timing(ops)

      report = %{
        mission: mission,
        ops: ops,
        tokens: tokens,
        timing: timing
      }

      {:ok, report}
    end
  end

  @doc """
  Formats a report as a printable string.
  """
  @spec format(map()) :: String.t()
  def format(report) do
    [
      format_header(report),
      format_timing_table(report),
      format_token_table(report),
      format_summary(report)
    ]
    |> Enum.join("\n")
  end

  # -- Private: data enrichment ------------------------------------------------

  defp enrich_jobs(ops, gitf_root) do
    Enum.map(ops, fn op ->
      ghost = if op.ghost_id, do: Archive.get(:ghosts, op.ghost_id)
      log_tokens = parse_bee_log(op.ghost_id, gitf_root)

      %{
        op_id: op.id,
        title: op.title,
        status: op.status,
        ghost_id: op.ghost_id,
        ghost_name: ghost && (ghost[:name] || op.ghost_id),
        started_at: ghost && ghost[:inserted_at],
        completed_at: ghost && ghost[:updated_at],
        duration: compute_duration(ghost),
        tokens: log_tokens
      }
    end)
  end

  defp parse_bee_log(nil, _gitf_root), do: empty_tokens()

  defp parse_bee_log(ghost_id, gitf_root) do
    log_path = Path.join([gitf_root, ".gitf", "run", "#{ghost_id}.log"])

    case File.read(log_path) do
      {:ok, content} ->
        events = StreamParser.parse_chunk(content)
        costs = StreamParser.extract_costs(events)

        Enum.reduce(costs, empty_tokens(), fn cost, acc ->
          %{
            input: acc.input + (cost[:input_tokens] || 0),
            output: acc.output + (cost[:output_tokens] || 0),
            cache_read: acc.cache_read + (cost[:cache_read_tokens] || 0),
            cache_create: acc.cache_create + (cost[:cache_write_tokens] || 0),
            cost_usd: acc.cost_usd + (cost[:cost_usd] || 0.0)
          }
        end)

      {:error, _} ->
        empty_tokens()
    end
  end

  defp empty_tokens do
    %{input: 0, output: 0, cache_read: 0, cache_create: 0, cost_usd: 0.0}
  end

  defp compute_duration(nil), do: nil

  defp compute_duration(ghost) do
    case {ghost[:inserted_at], ghost[:updated_at]} do
      {%DateTime{} = start, %DateTime{} = stop} ->
        DateTime.diff(stop, start, :second)

      _ ->
        nil
    end
  end

  defp aggregate_tokens(ops) do
    Enum.reduce(ops, empty_tokens(), fn op, acc ->
      t = op.tokens

      %{
        input: acc.input + t.input,
        output: acc.output + t.output,
        cache_read: acc.cache_read + t.cache_read,
        cache_create: acc.cache_create + t.cache_create,
        cost_usd: acc.cost_usd + t.cost_usd
      }
    end)
  end

  defp compute_timing(ops) do
    starts =
      ops
      |> Enum.map(& &1.started_at)
      |> Enum.reject(&is_nil/1)

    ends =
      ops
      |> Enum.map(& &1.completed_at)
      |> Enum.reject(&is_nil/1)

    first = if starts != [], do: Enum.min(starts, DateTime)
    last = if ends != [], do: Enum.max(ends, DateTime)

    wall_clock =
      if first && last, do: DateTime.diff(last, first, :second), else: nil

    %{
      started_at: first,
      completed_at: last,
      wall_clock_seconds: wall_clock
    }
  end

  # -- Private: formatting ---------------------------------------------------

  defp format_header(report) do
    q = report.mission
    status = String.upcase(q.status)

    lines = ["Quest Report: #{q.name} [#{status}]"]
    lines = if q[:goal], do: lines ++ ["Goal: #{q.goal}"], else: lines
    lines = lines ++ [String.duplicate("─", 60), ""]
    Enum.join(lines, "\n")
  end

  defp format_timing_table(report) do
    ops = report.ops

    if ops == [] do
      "No ops.\n"
    else
      # Detect parallelism: ops overlapping in time
      job_data =
        Enum.map(ops, fn j ->
          parallel = find_parallel_jobs(j, ops)
          duration_str = format_duration(j.duration)

          %{
            title: j.title || "-",
            ghost: j.ghost_name || "-",
            status: j.status,
            duration: duration_str,
            parallel: if(parallel == [], do: "-", else: Enum.join(parallel, ", "))
          }
        end)

      headers = ["Job", "Bee", "Status", "Duration", "Parallel?"]

      rows =
        Enum.map(job_data, fn j ->
          [j.title, j.ghost, j.status, j.duration, j.parallel]
        end)

      timing = report.timing

      wall =
        if timing.wall_clock_seconds do
          "\nWall clock: #{format_duration(timing.wall_clock_seconds)}"
        else
          ""
        end

      time_range =
        if timing.started_at && timing.completed_at do
          " (#{format_time(timing.started_at)} to #{format_time(timing.completed_at)})"
        else
          ""
        end

      "Timing\n" <> format_table(headers, rows) <> wall <> time_range <> "\n\n"
    end
  end

  defp format_token_table(report) do
    t = report.tokens
    total = t.input + t.output + t.cache_read + t.cache_create

    headers = ["Category", "Tokens", "Cost"]

    rows = [
      ["Input", format_number(t.input), format_cost(t.input, 3.0)],
      ["Output", format_number(t.output), format_cost(t.output, 15.0)],
      ["Cache read", format_number(t.cache_read), format_cost(t.cache_read, 0.30)],
      ["Cache create", format_number(t.cache_create), format_cost(t.cache_create, 3.75)],
      ["Total", format_number(total), "$#{:erlang.float_to_binary(t.cost_usd, decimals: 2)}"]
    ]

    "Token Usage & Cost\n" <> format_table(headers, rows) <> "\n"
  end

  defp format_summary(report) do
    ops = report.ops
    total = length(ops)
    done = Enum.count(ops, &(&1.status == "done"))
    failed = Enum.count(ops, &(&1.status == "failed"))

    ghost_ids = ops |> Enum.map(& &1.ghost_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    lines = [
      "Summary",
      "  #{total} ops, #{done} completed, #{failed} failed",
      "  #{length(ghost_ids)} ghosts spawned"
    ]

    Enum.join(lines, "\n") <> "\n"
  end

  # -- Private: table formatting -----------------------------------------------

  defp format_table(headers, rows) do
    all = [headers | rows]

    widths =
      Enum.map(0..(length(headers) - 1), fn i ->
        all
        |> Enum.map(fn row -> Enum.at(row, i, "") |> String.length() end)
        |> Enum.max()
      end)

    separator =
      widths
      |> Enum.map(&String.duplicate("─", &1 + 2))
      |> then(fn cols -> "├" <> Enum.join(cols, "┼") <> "┤" end)

    top =
      widths
      |> Enum.map(&String.duplicate("─", &1 + 2))
      |> then(fn cols -> "┌" <> Enum.join(cols, "┬") <> "┐" end)

    bottom =
      widths
      |> Enum.map(&String.duplicate("─", &1 + 2))
      |> then(fn cols -> "└" <> Enum.join(cols, "┴") <> "┘" end)

    format_row = fn row ->
      shells =
        row
        |> Enum.zip(widths)
        |> Enum.map(fn {val, w} -> " " <> String.pad_trailing(val, w) <> " " end)

      "│" <> Enum.join(shells, "│") <> "│"
    end

    header_line = format_row.(headers)

    body_lines =
      rows
      |> Enum.map(format_row)
      |> Enum.intersperse(separator)

    Enum.join([top, header_line, separator | body_lines] ++ [bottom], "\n") <> "\n"
  end

  # -- Private: helpers -------------------------------------------------------

  defp find_parallel_jobs(op, all_jobs) do
    case {op.started_at, op.completed_at} do
      {%DateTime{} = s1, %DateTime{} = e1} ->
        all_jobs
        |> Enum.reject(&(&1.op_id == op.op_id))
        |> Enum.filter(fn other ->
          case {other.started_at, other.completed_at} do
            {%DateTime{} = s2, %DateTime{} = e2} ->
              DateTime.compare(s1, e2) == :lt and DateTime.compare(s2, e1) == :lt

            _ ->
              false
          end
        end)
        |> Enum.map(& &1.title)

      _ ->
        []
    end
  end

  defp format_duration(nil), do: "-"

  defp format_duration(seconds) when is_integer(seconds) do
    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
    end
  end

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_cost(tokens, rate_per_million) do
    cost = tokens * rate_per_million / 1_000_000
    "$#{:erlang.float_to_binary(cost, decimals: 2)}"
  end

  defp gitf_root do
    case GiTF.gitf_dir() do
      {:ok, root} -> root
      _ -> "."
    end
  end
end
