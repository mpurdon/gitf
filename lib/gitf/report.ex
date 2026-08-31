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
      # One ledger read per report, not one collection scan per op.
      costs_by_ghost = mission.id |> GiTF.Costs.for_quest() |> Enum.group_by(& &1.ghost_id)
      ops = enrich_jobs(mission.ops, gitf_root, costs_by_ghost)
      tokens = aggregate_tokens(ops)
      timing = compute_timing(ops)
      files = aggregate_files(mission.ops)
      artifacts = collect_artifacts(mission)

      report = %{
        mission: mission,
        ops: ops,
        tokens: tokens,
        timing: timing,
        files: files,
        artifacts: artifacts
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
      format_files_section(report),
      format_token_table(report),
      format_artifacts_section(report),
      format_summary(report)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @doc """
  Returns report data structured for HTML rendering in LiveView.
  """
  @spec for_display(map()) :: map()
  def for_display(report) do
    %{
      mission_name: report.mission[:name] || report.mission.id,
      mission_status: report.mission.status,
      post_processing_status: report.mission[:post_processing_status],
      goal: report.mission[:goal],
      timing: %{
        wall_clock: format_duration(report.timing.wall_clock_seconds),
        started_at: report.timing.started_at && format_time(report.timing.started_at),
        completed_at: report.timing.completed_at && format_time(report.timing.completed_at)
      },
      tokens: report.tokens,
      total_tokens:
        report.tokens.input + report.tokens.output + report.tokens.cache_read +
          report.tokens.cache_create,
      ops: Enum.map(report.ops, &format_op_for_display/1),
      files: report.files,
      file_summary: summarize_files(report.files),
      pr_url:
        get_in(report, [:artifacts, :publish, "pr_url"]) ||
          get_in(report, [:artifacts, :sync, "pr_url"]),
      sync_status: get_in(report, [:artifacts, :sync, "status"]),
      quality_score: get_in(report, [:artifacts, :scoring, "overall_score"]),
      summary: compute_display_summary(report.ops)
    }
  end

  # -- Private: data enrichment ------------------------------------------------

  defp enrich_jobs(ops, gitf_root, costs_by_ghost) do
    Enum.map(ops, fn op ->
      ghost_id = Map.get(op, :ghost_id)
      ghost = if ghost_id, do: Archive.get(:ghosts, ghost_id)
      log_tokens = tokens_for_ghost(ghost_id, gitf_root, costs_by_ghost)

      %{
        op_id: op.id,
        title: Map.get(op, :title, "-"),
        status: Map.get(op, :status, "unknown"),
        ghost_id: ghost_id,
        ghost_name: ghost && (ghost[:name] || ghost_id),
        started_at: ghost && ghost[:inserted_at],
        completed_at: ghost && ghost[:updated_at],
        duration: compute_duration(ghost),
        tokens: log_tokens,
        files_changed: Map.get(op, :files_changed, 0),
        phase_job: Map.get(op, :phase_job, false)
      }
    end)
  end

  # The cost ledger is the source of truth — every provider path records
  # into it, and it survives log rotation. Parsing the stream-json log is
  # the fallback for a ghost that predates the ledger; on the box the
  # report was showing 0 tokens for a $9.91 mission because the log path
  # it guessed did not exist there.
  defp tokens_for_ghost(nil, _gitf_root, _costs), do: empty_tokens()

  defp tokens_for_ghost(ghost_id, gitf_root, costs_by_ghost) do
    case Map.get(costs_by_ghost, ghost_id, []) do
      [] -> parse_bee_log(ghost_id, gitf_root)
      costs -> sum_tokens(costs)
    end
  end

  defp sum_tokens(costs) do
    Enum.reduce(costs, empty_tokens(), fn cost, acc ->
      %{
        input: acc.input + (cost[:input_tokens] || 0),
        output: acc.output + (cost[:output_tokens] || 0),
        cache_read: acc.cache_read + (cost[:cache_read_tokens] || 0),
        cache_create: acc.cache_create + (cost[:cache_write_tokens] || 0),
        cost_usd: acc.cost_usd + (cost[:cost_usd] || 0.0)
      }
    end)
  end

  defp parse_bee_log(nil, _gitf_root), do: empty_tokens()

  defp parse_bee_log(ghost_id, gitf_root) do
    log_path = Path.join([gitf_root, ".gitf", "run", "#{ghost_id}.log"])

    case File.read(log_path) do
      {:ok, content} ->
        content |> StreamParser.parse_chunk() |> StreamParser.extract_costs() |> sum_tokens()

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

    status =
      case q[:post_processing_status] do
        "pending" -> "#{String.upcase(q.status)} (scoring…)"
        "failed" -> "#{String.upcase(q.status)} (scoring failed)"
        _ -> String.upcase(q.status)
      end

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

      headers = ["Job", "Ghost", "Status", "Duration", "Parallel?"]

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

    ghost_ids = ops |> Enum.map(&Map.get(&1, :ghost_id)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    lines = [
      "Summary",
      "  #{total} ops, #{done} completed, #{failed} failed",
      "  #{length(ghost_ids)} ghosts spawned"
    ]

    Enum.join(lines, "\n") <> "\n"
  end

  # -- Private: file & artifact aggregation ------------------------------------

  defp aggregate_files(ops) do
    ops
    |> Enum.reject(& &1[:phase_job])
    |> Enum.flat_map(fn op ->
      case op[:changed_files_detail] do
        details when is_list(details) and details != [] ->
          details

        _ ->
          # Fallback: treat all as modified
          (op[:changed_files] || [])
          |> Enum.map(&%{status: "M", path: &1})
      end
    end)
    |> Enum.uniq_by(& &1.path)
    |> Enum.sort_by(& &1.path)
  end

  defp collect_artifacts(mission) do
    %{
      sync: GiTF.Missions.get_artifact(mission.id, "sync"),
      scoring: GiTF.Missions.get_artifact(mission.id, "scoring")
    }
  end

  defp format_op_for_display(op) do
    %{
      title: op.title,
      status: op.status,
      duration: format_duration(op.duration),
      files_changed: op.files_changed,
      cost_usd: op.tokens.cost_usd,
      ghost_name: op.ghost_name,
      phase_job: op.phase_job
    }
  end

  defp summarize_files(files) do
    %{
      added: Enum.count(files, &(&1.status == "A")),
      modified: Enum.count(files, &(&1.status == "M")),
      deleted: Enum.count(files, &(&1.status == "D")),
      total: length(files)
    }
  end

  defp compute_display_summary(ops) do
    %{
      total_ops: length(ops),
      done: Enum.count(ops, &(&1.status == "done")),
      failed: Enum.count(ops, &(&1.status == "failed")),
      ghosts: ops |> Enum.map(& &1.ghost_id) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length()
    }
  end

  defp format_files_section(%{files: files}) when is_list(files) and files != [] do
    lines =
      Enum.map(files, fn f ->
        icon =
          case f.status do
            "A" -> "+"
            "D" -> "-"
            _ -> "~"
          end

        "  #{icon} #{f.path}"
      end)

    "Files Changed (#{length(files)})\n" <> Enum.join(lines, "\n") <> "\n"
  end

  defp format_files_section(_), do: nil

  defp format_artifacts_section(%{artifacts: %{sync: sync, scoring: scoring}} = report) do
    publish = get_in(report, [:artifacts, :publish])

    lines =
      [
        ((publish && publish["pr_url"]) || (sync && sync["pr_url"])) &&
          "  PR: #{(publish && publish["pr_url"]) || sync["pr_url"]}",
        sync && sync["status"] && "  Sync: #{sync["status"]}",
        scoring && scoring["overall_score"] && "  Quality: #{scoring["overall_score"]}"
      ]
      |> Enum.reject(&is_nil/1)

    if lines != [], do: "Artifacts\n" <> Enum.join(lines, "\n") <> "\n", else: nil
  end

  defp format_artifacts_section(_), do: nil

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
