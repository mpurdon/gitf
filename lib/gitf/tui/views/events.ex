defmodule GiTF.TUI.Views.Events do
  @moduledoc "Renders the EventStore timeline."
  import Ratatouille.View

  def render(model) do
    events = model[:event_store_events] || []

    panel title: "Events [F3]", height: :fill do
      if Enum.empty?(events) do
        label(content: "No events recorded", color: :white)
      else
        Enum.map(events, fn event ->
          ts =
            case event[:timestamp] do
              %DateTime{} = dt -> Calendar.strftime(dt, "%H:%M:%S")
              _ -> "  --  "
            end

          type = to_string(event[:type] || "?")
          entity = short_id(event[:entity_id])
          summary = event_summary(event[:data])

          label do
            text(content: ts <> " ", color: :white)
            text(content: String.pad_trailing(type, 16), color: type_color(event[:type]))
            text(content: entity <> " ", color: :cyan)
            text(content: summary, color: :white)
          end
        end)
      end
    end
  end

  defp short_id(nil), do: "        "
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8) |> String.pad_trailing(8)
  defp short_id(id), do: to_string(id) |> short_id()

  defp event_summary(data) when is_map(data) do
    data
    |> Map.drop([:__struct__])
    |> Enum.take(2)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{inspect(v, limit: 30)}" end)
    |> String.slice(0, 40)
  end

  defp event_summary(_), do: ""

  defp type_color(t) when t in [:bee_spawned, :bee_completed, :bee_failed, :bee_stopped],
    do: :blue

  defp type_color(t) when t in [:job_created, :job_transition, :job_verified, :job_rejected],
    do: :yellow

  defp type_color(t) when t in [:quest_created, :quest_completed, :quest_failed], do: :green
  defp type_color(t) when t in [:merge_started, :merge_succeeded, :merge_failed], do: :magenta
  defp type_color(:error), do: :red
  defp type_color(_), do: :white
end
