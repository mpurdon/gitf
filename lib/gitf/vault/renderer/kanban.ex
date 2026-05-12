defmodule GiTF.Vault.Renderer.Kanban do
  @moduledoc """
  Renders a sector's Obsidian Kanban board (`002_kanban.md`).

  The Obsidian Kanban plugin recognises any markdown file with the
  `kanban-plugin: basic` frontmatter and treats `## Lane` H2 headers as
  columns and `- [ ] item` lines as cards. We render entries as
  `[[mission-id]]` wikilinks so the kanban is just a view, not a
  duplication of the mission state — moving a card requires editing the
  mission file (or, in M3, the kanban itself becomes a control plane).

  ## Lanes

  Missions are bucketed into lanes by `status`:

  | Lane    | Statuses                                                  |
  |---------|-----------------------------------------------------------|
  | Todo    | pending, planning, requirements                           |
  | Doing   | active, research, design, implementation, validation      |
  | Review  | review, awaiting_approval                                 |
  | Done    | completed, merged                                         |

  Failed and closed missions are rendered into a separate section below
  the Done lane for traceability without polluting the operator's view.
  """

  @lane_order ["Todo", "Doing", "Review", "Done"]

  @status_to_lane %{
    "pending" => "Todo",
    "planning" => "Todo",
    "requirements" => "Todo",
    "active" => "Doing",
    "research" => "Doing",
    "design" => "Doing",
    "implementation" => "Doing",
    "validation" => "Doing",
    "review" => "Review",
    "awaiting_approval" => "Review",
    "completed" => "Done",
    "merged" => "Done"
  }

  @doc """
  Renders the kanban for `sector_id` given a list of mission records.

  Each mission entry is `- [ ] [[<mission-file-base>]] <one-line goal>`
  where `<mission-file-base>` is `<mission_id>-<slugified-title>` to
  match the file under `Missions/`.

  Options:
    * `:closed_section` — when true (default), include a `## Closed` lane
      below Done with failed/closed missions.
  """
  @spec render(String.t(), [map()], keyword()) :: String.t()
  def render(sector_id, missions, opts \\ []) when is_list(missions) do
    closed_section = Keyword.get(opts, :closed_section, true)
    by_lane = group_by_lane(missions)

    main_lanes =
      @lane_order
      |> Enum.map(fn lane ->
        cards = Map.get(by_lane, lane, [])
        render_lane(lane, cards)
      end)
      |> Enum.join("\n\n")

    closed_block =
      if closed_section and Map.get(by_lane, :closed, []) != [] do
        "\n\n" <> render_closed(Map.get(by_lane, :closed, []))
      else
        ""
      end

    """
    ---
    kanban-plugin: basic
    sector: #{sector_id}
    ---

    #{main_lanes}#{closed_block}

    %% kanban:settings
    {"kanban-plugin":"basic","show-checkboxes":true}
    %%
    """
  end

  # -- Helpers ---------------------------------------------------------------

  defp group_by_lane(missions) do
    Enum.reduce(missions, %{}, fn m, acc ->
      lane = lane_for(m)
      Map.update(acc, lane, [m], fn existing -> [m | existing] end)
    end)
    |> Map.new(fn {lane, ms} -> {lane, sort_missions(ms)} end)
  end

  defp lane_for(%{status: s}) when s in ["failed", "closed"], do: :closed
  defp lane_for(%{status: s}), do: Map.get(@status_to_lane, to_string(s), "Todo")
  defp lane_for(_), do: "Todo"

  defp sort_missions(missions) do
    # Higher priority first, then most-recently-created last (so newer
    # cards stack at the top).
    Enum.sort_by(
      missions,
      fn m -> {-priority_rank(m[:priority]), -unix(m[:inserted_at] || m[:priority_set_at])} end
    )
  end

  defp priority_rank(:critical), do: 4
  defp priority_rank(:high), do: 3
  defp priority_rank(:normal), do: 2
  defp priority_rank(:low), do: 1
  defp priority_rank(p) when is_binary(p), do: priority_rank(safe_atom(p))
  defp priority_rank(_), do: 2

  defp safe_atom(s) do
    String.to_existing_atom(s)
  rescue
    _ -> :normal
  end

  defp unix(%DateTime{} = dt), do: DateTime.to_unix(dt)
  defp unix(_), do: 0

  defp render_lane(lane, cards) do
    "## #{lane}\n\n" <>
      case cards do
        [] -> ""
        list -> Enum.map(list, &card_line/1) |> Enum.join("\n")
      end
  end

  defp render_closed(cards) do
    "## Closed\n\n" <> (Enum.map(cards, &card_line/1) |> Enum.join("\n"))
  end

  defp card_line(mission) do
    file_base = file_base(mission)
    summary = summary_for(mission)
    "- [ ] [[#{file_base}]]#{summary}"
  end

  defp file_base(mission), do: GiTF.Vault.Path.mission_file_base(mission)

  defp summary_for(mission) do
    case mission[:goal] do
      nil ->
        ""

      "" ->
        ""

      goal ->
        " — " <> short(goal, 80)
    end
  end

  defp short(s, n) when is_binary(s) and byte_size(s) <= n, do: String.replace(s, "\n", " ")
  defp short(s, n) when is_binary(s), do: String.slice(s, 0, n) <> "…"
  defp short(_, _), do: ""
end
