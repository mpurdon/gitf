defmodule GiTF.TUI.Views.Activity do
  @moduledoc """
  Renders the activity panel with missions, phase progress, their ghosts,
  budget info, backups, and active runs.
  """
  import Ratatouille.View

  require GiTF.Ghost.Status, as: GhostStatus

  @phases ~w(research requirements design review planning implementation validation sync)

  def render(model) do
    %{activity: activity} = model
    ghosts_by_mission = Enum.group_by(activity.ghosts, fn b -> b[:mission_id] end)
    budget_status = model[:budget_status] || []
    backups = model[:backups] || %{}
    runs = model[:runs] || []

    panel title: "Activity [F1]", height: :fill do
      if Enum.empty?(activity.missions) and Enum.empty?(activity.ghosts) do
        label(content: "Idle")
      else
        render_quests(activity.missions, ghosts_by_mission, activity.ghost_logs, budget_status, backups) ++
          render_orphan_ghosts(ghosts_by_mission, activity.ghost_logs, backups) ++
          render_runs(runs)
      end
    end
  end

  defp render_quests(missions, ghosts_by_mission, ghost_logs, budget_status, backups) do
    Enum.flat_map(missions, fn mission ->
      mission_id = mission[:id]
      mission_ghosts = Map.get(ghosts_by_mission, mission_id, [])
      current_phase = mission[:current_phase] || mission[:status]
      name = to_s(mission[:name] || mission[:goal] || mission[:title])
      short_name = String.slice(name, 0, 30)
      artifacts = mission[:artifacts] || %{}
      budget = Enum.find(budget_status, &(&1.mission_id == mission_id))

      {budget_text, budget_color} = format_budget(budget)

      [
        label do
          text(content: short_name, color: :yellow, attributes: [:bold])
          text(content: budget_text, color: budget_color)
        end
      ] ++
        render_phase_tracker(current_phase, artifacts, mission_ghosts, ghost_logs, backups) ++
        [label(content: "")]
    end)
  end

  defp render_phase_tracker(current_phase, artifacts, ghosts, ghost_logs, backups) do
    Enum.flat_map(@phases, fn phase ->
      {marker, color} =
        cond do
          Map.has_key?(artifacts, phase) -> {"v", :green}
          phase == to_s(current_phase) -> {"~", :yellow}
          true -> {".", :white}
        end

      phase_label = [
        label do
          text(content: " #{marker} ", color: color)
          text(content: phase, color: color)
        end
      ]

      # Show active ghosts under the current phase
      ghost_labels =
        if phase == to_s(current_phase) do
          Enum.flat_map(ghosts, fn ghost ->
            ghost_id = to_s(ghost[:id])
            status = to_s(ghost[:status] || ghost[:state])
            log_lines = Map.get(ghost_logs, ghost[:id], [])
            backup = Map.get(backups, ghost[:id])

            [
              label do
                text(content: "   #{ghost_id}", color: :cyan)
                text(content: " [#{status}]", color: status_color(status))
              end
            ] ++
              render_checkpoint(backup) ++
              Enum.map(log_lines, fn line ->
                label(content: "     #{line}", color: :white)
              end)
          end)
        else
          []
        end

      phase_label ++ ghost_labels
    end)
  end

  defp render_checkpoint(nil), do: []

  defp render_checkpoint(cp) do
    iter = cp[:iteration] || "?"
    ctx = cp[:context_usage_pct] || 0
    ctx_pct = Float.round(ctx * 100, 0)
    files = length(cp[:files_modified] || [])
    errors = cp[:error_count] || 0

    ctx_color =
      cond do
        ctx_pct > 80 -> :red
        ctx_pct > 60 -> :yellow
        true -> :green
      end

    error_part = if errors > 0, do: " err:#{errors}", else: ""

    [
      label do
        text(content: "     iter:#{iter}", color: :white)
        text(content: " ctx:#{trunc(ctx_pct)}%", color: ctx_color)
        text(content: " files:#{files}", color: :white)
        text(content: error_part, color: :red)
      end
    ]
  end

  defp render_orphan_ghosts(ghosts_by_mission, ghost_logs, backups) do
    case Map.get(ghosts_by_mission, nil, []) do
      [] -> []
      ghosts -> render_bees(ghosts, ghost_logs, "", backups)
    end
  end

  defp render_bees(ghosts, ghost_logs, indent, backups) do
    Enum.flat_map(ghosts, fn ghost ->
      ghost_id = to_s(ghost[:id])
      status = to_s(ghost[:status] || ghost[:state])
      log_lines = Map.get(ghost_logs, ghost[:id], [])
      backup = Map.get(backups, ghost[:id])

      [
        label do
          text(content: indent <> ghost_id, color: :cyan)
          text(content: " [#{status}]", color: status_color(status))
        end
      ] ++
        render_checkpoint(backup) ++
        Enum.map(log_lines, fn line ->
          label(content: indent <> "  " <> line, color: :white)
        end)
    end)
  end

  defp render_runs([]), do: []

  defp render_runs(runs) do
    [
      label(content: ""),
      label(content: "Active Runs", color: :white, attributes: [:bold])
    ] ++
      Enum.flat_map(runs, fn run ->
        pct =
          if run.total_jobs > 0,
            do: Float.round(run.completed_jobs / run.total_jobs * 100, 0),
            else: 0

        bar_len = 12
        filled = trunc(pct / 100 * bar_len)
        bar_str = String.duplicate("█", filled) <> String.duplicate("░", bar_len - filled)

        [
          label do
            text(content: " #{String.slice(run.mission_id, 0, 10)} ", color: :white)
            text(content: bar_str, color: :blue)
            text(content: " #{trunc(pct)}%", color: :cyan)
          end
        ]
      end)
  end

  defp format_budget(nil), do: {"", :white}

  defp format_budget(budget) do
    pct = if budget.budget > 0, do: Float.round(budget.spent / budget.budget * 100, 0), else: 0

    color =
      cond do
        pct >= 80 -> :red
        pct >= 60 -> :yellow
        true -> :green
      end

    {" $#{Float.round(budget.spent, 2)}/#{Float.round(budget.budget, 2)}", color}
  end

  defp to_s(nil), do: "?"
  defp to_s(val) when is_binary(val), do: val
  defp to_s(val), do: inspect(val)

  defp status_color(GhostStatus.working()), do: :green
  defp status_color(GhostStatus.provisioning()), do: :yellow
  defp status_color(GhostStatus.stopped()), do: :white
  defp status_color("failed"), do: :red
  defp status_color(_), do: :white
end
