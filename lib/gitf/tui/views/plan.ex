defmodule GiTF.TUI.Views.Plan do
  @moduledoc """
  Renders the plan review panel.

  Shows plan sections as a navigable checklist. Each section can be
  accepted or rejected. Replaces the Activity panel when in plan mode.
  """
  import Ratatouille.View

  alias GiTF.TUI.Context.Plan

  def render(model) do
    %{plan: plan} = model

    panel title: plan_title(plan), height: :fill do
      if plan.goal do
        label(content: "Goal: #{String.slice(plan.goal, 0, 50)}", color: :yellow)
        label(content: "")
      end

      render_sections(plan.sections, plan.selected) ++
        [label(content: "")] ++
        render_footer(plan)
    end
  end

  defp plan_title(plan) do
    base = if plan.mission_id, do: "Plan: #{String.slice(plan.mission_id, 0, 12)}", else: "Plan"

    case Plan.current_strategy(plan) do
      {strategy, score} ->
        suffix = if Plan.candidate_count(plan) > 1, do: " [Tab: switch]", else: ""
        "#{base} (#{strategy}, #{Float.round(score, 2)})#{suffix}"

      _ ->
        base
    end
  end

  defp render_sections(sections, selected) do
    sections
    |> Enum.with_index()
    |> Enum.flat_map(fn {section, idx} ->
      is_selected = idx == selected

      {marker, marker_color} =
        case section.status do
          :accepted -> {"v", :green}
          :rejected -> {"x", :red}
          :pending when is_selected -> {">", :yellow}
          :pending -> {" ", :white}
        end

      title_attrs = if is_selected, do: [:bold], else: []
      title_color = if is_selected, do: :yellow, else: :white

      [
        label do
          text(content: " #{marker} ", color: marker_color, attributes: title_attrs)
          text(content: section.title, color: title_color, attributes: title_attrs)
        end
      ] ++
        if is_selected do
          desc_lines =
            section.description
            |> String.slice(0, 200)
            |> String.split("\n")
            |> Enum.take(3)

          desc_labels =
            Enum.map(desc_lines, fn line ->
              label(content: "     #{line}", color: :white)
            end)

          file_label =
            if section.target_files != [] do
              [
                label(
                  content: "     Files: #{Enum.join(section.target_files, ", ")}",
                  color: :cyan
                )
              ]
            else
              []
            end

          model_label =
            if section.model do
              [label(content: "     Model: #{section.model}", color: :white)]
            else
              []
            end

          desc_labels ++ file_label ++ model_label ++ [label(content: "")]
        else
          []
        end
    end)
  end

  defp render_footer(plan) do
    cond do
      Plan.all_accepted?(plan) ->
        [
          label(content: "---", color: :white),
          label do
            text(content: " All accepted! ", color: :green, attributes: [:bold])
            text(content: "Press Enter to confirm.", color: :white)
          end
        ]

      plan.mode == :reviewing ->
        tab_hint =
          if Plan.candidate_count(plan) > 1 do
            [
              label do
                text(content: " Tab ", color: :cyan)
                text(content: "switch plan  ", color: :white)
                text(content: "a ", color: :cyan)
                text(content: "accept all  ", color: :white)
                text(content: "q ", color: :cyan)
                text(content: "cancel", color: :white)
              end
            ]
          else
            [
              label do
                text(content: " a ", color: :cyan)
                text(content: "accept all  ", color: :white)
                text(content: "q ", color: :cyan)
                text(content: "cancel", color: :white)
              end
            ]
          end

        [
          label(content: "---", color: :white),
          label do
            text(content: " ^/v ", color: :cyan)
            text(content: "navigate  ", color: :white)
            text(content: "y ", color: :green)
            text(content: "accept  ", color: :white)
            text(content: "n ", color: :red)
            text(content: "reject  ", color: :white)
          end
        ] ++ tab_hint

      true ->
        []
    end
  end
end
