defmodule Hive.TUI.Views.Merges do
  @moduledoc "Renders the merge queue view."
  import Ratatouille.View

  def render(model) do
    mq = model[:merge_queue] || %{pending: [], active: nil, completed: []}

    panel title: "Merges [F4]", height: :fill do
      # Active
      [label(content: "ACTIVE", color: :white, attributes: [:bold])] ++
        render_active(mq[:active]) ++
        [label(content: "")] ++
        # Pending
        [label do
          text(content: "PENDING ", color: :white, attributes: [:bold])
          text(content: "(#{length(mq[:pending] || [])})", color: :yellow)
        end] ++
        render_pending(mq[:pending] || []) ++
        [label(content: "")] ++
        # Completed
        [label(content: "RECENT", color: :white, attributes: [:bold])] ++
        render_completed(mq[:completed] || [])
    end
  end

  defp render_active(nil), do: [label(content: "  (idle)", color: :white)]

  defp render_active(active) do
    job_id = short_id(active[:job_id] || active.job_id)
    cell_id = to_string(active[:cell_id] || active.cell_id)

    [
      label do
        text(content: "  >> ", color: :blue, attributes: [:bold])
        text(content: job_id, color: :cyan)
        text(content: " cell:#{cell_id}", color: :white)
      end
    ]
  end

  defp render_pending([]), do: [label(content: "  (empty)", color: :white)]

  defp render_pending(items) do
    items
    |> Enum.with_index(1)
    |> Enum.map(fn {{job_id, cell_id}, idx} ->
      label do
        text(content: "  #{idx}. ", color: :white)
        text(content: short_id(job_id), color: :cyan)
        text(content: " cell:#{cell_id}", color: :white)
      end
    end)
  end

  defp render_completed([]), do: [label(content: "  (none)", color: :white)]

  defp render_completed(items) do
    Enum.map(items, fn {job_id, outcome, timestamp} ->
      ts =
        case timestamp do
          %DateTime{} = dt -> Calendar.strftime(dt, "%H:%M:%S")
          _ -> "--:--:--"
        end

      label do
        text(content: "  #{short_id(job_id)} ", color: :cyan)
        text(content: String.pad_trailing(format_outcome(outcome), 10), color: outcome_color(outcome))
        text(content: ts, color: :white)
      end
    end)
  end

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(id), do: to_string(id) |> String.slice(0, 8)

  defp format_outcome(:success), do: "success"
  defp format_outcome(:crash), do: "crash"
  defp format_outcome({:failure, _}), do: "failure"
  defp format_outcome({:reimagined, _}), do: "reimagined"
  defp format_outcome(other), do: to_string(other)

  defp outcome_color(:success), do: :green
  defp outcome_color(:crash), do: :red
  defp outcome_color({:failure, _}), do: :red
  defp outcome_color({:reimagined, _}), do: :yellow
  defp outcome_color(_), do: :white
end
