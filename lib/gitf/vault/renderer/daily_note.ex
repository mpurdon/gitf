defmodule GiTF.Vault.Renderer.DailyNote do
  @moduledoc """
  Renders the Major's daily standup note.

  Pure: takes a `%{date, missions:, ghosts:, sectors:, costs:}` snapshot
  and returns markdown. The Writer is responsible for assembling the
  snapshot from Archive state at render time.

  Snapshot shape (all fields optional; missing → empty section):

      %{
        date: ~D[2026-05-04],
        missions: %{
          merged_today: [mission_map, ...],
          failed_today: [mission_map, ...],
          in_flight: [mission_map, ...],
          planned_today: [mission_map, ...]
        },
        ghosts: %{
          active: [ghost_map, ...]      # currently working
        },
        sectors: [
          %{id: "frontend", todo: 1, doing: 2, review: 0, done: 12}
        ],
        costs: %{today_usd: 4.20, week_usd: 17.18},
        factory_uptime_h: 23.5
      }
  """

  @doc "Renders a daily-note markdown document for the given snapshot."
  @spec render(map()) :: String.t()
  def render(snapshot) when is_map(snapshot) do
    date = Map.get(snapshot, :date, Date.utc_today())
    missions = Map.get(snapshot, :missions, %{})
    ghosts = Map.get(snapshot, :ghosts, %{})
    sectors = Map.get(snapshot, :sectors, [])
    costs = Map.get(snapshot, :costs, %{})
    uptime_h = Map.get(snapshot, :factory_uptime_h)

    [
      frontmatter(date, missions, uptime_h),
      "",
      "# #{Date.to_iso8601(date)} — Standup",
      "",
      yesterday_section(missions),
      today_section(missions),
      active_section(Map.get(ghosts, :active, [])),
      sectors_section(sectors),
      costs_section(costs)
    ]
    |> Enum.reject(&(&1 == "" or is_nil(&1)))
    |> Enum.intersperse("\n")
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  # -- Sections --------------------------------------------------------------

  defp frontmatter(date, missions, uptime_h) do
    GiTF.Vault.YAML.frontmatter([
      {"date", Date.to_iso8601(date)},
      {"missions_in_flight", length(Map.get(missions, :in_flight, []))},
      {"missions_merged_today", length(Map.get(missions, :merged_today, []))},
      {"missions_failed_today", length(Map.get(missions, :failed_today, []))},
      {"factory_uptime_h", GiTF.Vault.YAML.format_float(uptime_h)}
    ])
  end

  defp yesterday_section(missions) do
    merged = Map.get(missions, :merged_today, [])
    failed = Map.get(missions, :failed_today, [])

    if merged == [] and failed == [] do
      ""
    else
      lines =
        Enum.map(merged, &"- ✅ Merged [[#{file_base(&1)}]] in [[#{sector_index_link(&1)}]]") ++
          Enum.map(
            failed,
            &"- ❌ [[#{file_base(&1)}]] failed (sector [[#{sector_index_link(&1)}]])"
          )

      "## Yesterday\n\n" <> Enum.join(lines, "\n")
    end
  end

  defp today_section(missions) do
    in_flight = Map.get(missions, :in_flight, [])

    if in_flight == [] do
      ""
    else
      lines =
        Enum.map(in_flight, fn m ->
          phase = m[:current_phase] || m[:status] || "?"
          "- [[#{file_base(m)}]] · #{phase}"
        end)

      "\n## Today\n\n" <> Enum.join(lines, "\n")
    end
  end

  defp active_section([]), do: ""

  defp active_section(ghosts) do
    lines =
      Enum.map(ghosts, fn g ->
        op = g[:current_op] || g[:op_id] || ""
        op_part = if op == "", do: "", else: " — op #{op}"
        "- [[#{g[:name] || g[:id]}]]#{op_part}"
      end)

    "\n## Active employees\n\n" <> Enum.join(lines, "\n")
  end

  defp sectors_section([]), do: ""

  defp sectors_section(sectors) do
    lines =
      Enum.map(sectors, fn s ->
        "- [[Sectors/#{s[:id]}/002_kanban|#{s[:id]}]] — #{s[:todo] || 0} / #{s[:doing] || 0} / #{s[:review] || 0} / #{s[:done] || 0} (Todo/Doing/Review/Done)"
      end)

    "\n## Sectors\n\n" <> Enum.join(lines, "\n")
  end

  defp costs_section(%{} = costs) when map_size(costs) > 0 do
    today = format_money(costs[:today_usd])
    week = format_money(costs[:week_usd])
    "\n## Costs\n\nToday $#{today} · This week $#{week}"
  end

  defp costs_section(_), do: ""

  # -- Helpers ---------------------------------------------------------------

  defp file_base(m), do: GiTF.Vault.Path.mission_file_base(m)

  defp sector_index_link(m) do
    "Sectors/#{m[:sector_id] || "_global"}/001_index"
  end

  defp format_money(nil), do: "0.00"
  defp format_money(f) when is_float(f), do: :erlang.float_to_binary(f, decimals: 2)
  defp format_money(n), do: to_string(n)
end
