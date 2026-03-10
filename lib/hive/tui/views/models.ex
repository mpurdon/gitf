defmodule Hive.TUI.Views.Models do
  @moduledoc "Renders agent identity / model performance cards."
  import Ratatouille.View

  def render(model) do
    identities = model[:agent_identities] || []

    panel title: "Models [F5]", height: :fill do
      if Enum.empty?(identities) do
        label(content: "No model data yet", color: :white)
      else
        Enum.flat_map(identities, fn id ->
          pass_rate = if id.total_jobs > 0, do: id.total_passed / id.total_jobs * 100, else: 0
          rate_color = cond do
            pass_rate >= 80 -> :green
            pass_rate >= 60 -> :yellow
            true -> :red
          end

          scores = id.avg_scores || %{}

          [
            label do
              text(content: id.model, color: :yellow, attributes: [:bold])
              text(content: "  #{id.total_jobs} jobs  ", color: :white)
              text(content: "#{Float.round(pass_rate, 0)}%", color: rate_color, attributes: [:bold])
            end,
            label do
              score_bar("cor", scores[:correctness])
              text(content: "  ")
              score_bar("cpl", scores[:completeness])
              text(content: "  ")
              score_bar("qal", scores[:code_quality])
              text(content: "  ")
              score_bar("eff", scores[:efficiency])
            end
          ] ++
            render_traits(id) ++
            [label(content: "")]
        end)
      end
    end
  end

  defp score_bar(label, nil), do: text(content: "#{label}:--", color: :white)

  defp score_bar(label, score) do
    pct = Float.round(score * 100, 0)
    color = cond do
      pct >= 80 -> :green
      pct >= 60 -> :yellow
      true -> :red
    end

    text(content: "#{label}:#{trunc(pct)}%", color: color)
  end

  defp render_traits(id) do
    strengths = Enum.take(id.strengths || [], 3)
    weaknesses = Enum.take(id.weaknesses || [], 3)

    s_labels =
      if strengths != [] do
        [
          label do
            text(content: "  + ", color: :green)
            text(content: Enum.map_join(strengths, ", ", & &1.trait), color: :green)
          end
        ]
      else
        []
      end

    w_labels =
      if weaknesses != [] do
        [
          label do
            text(content: "  - ", color: :red)
            text(content: Enum.map_join(weaknesses, ", ", & &1.trait), color: :red)
          end
        ]
      else
        []
      end

    s_labels ++ w_labels
  end
end
