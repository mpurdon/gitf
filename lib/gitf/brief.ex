defmodule GiTF.Brief do
  @moduledoc """
  Generates context prompts for Claude Code sessions.

  Priming is the act of feeding Claude its initial context at session start.
  The Major gets the QUEEN.md instructions plus a snapshot of the current
  section state. A Bee gets its specific op description, relevant links,
  and information about the sector it is working on.

  Output is Markdown text, ready for Claude to parse.
  """

  alias GiTF.Archive

  # -- Public API ------------------------------------------------------------

  @doc """
  Briefs a Major or Bee with context for a Claude Code session.

  - `brief(:major, gitf_root)` reads QUEEN.md and appends current section state
  - `brief(:ghost, ghost_id)` builds a briefing from the ghost's op, shell, and links

  Returns `{:ok, markdown}` or `{:error, reason}`.
  """
  @spec brief(:major | :ghost, String.t()) :: {:ok, String.t()} | {:error, term()}
  def brief(role, identifier)

  def brief(:major, gitf_root) do
    queen_md_path = Path.join([gitf_root, ".gitf", "major", "QUEEN.md"])

    with {:ok, instructions} <- File.read(queen_md_path) do
      state_summary = build_major_state_summary()
      {:ok, instructions <> "\n\n" <> state_summary}
    end
  end

  def brief(:ghost, ghost_id) do
    with {:ok, ghost} <- fetch_bee(ghost_id) do
      markdown = build_bee_briefing(ghost)
      transfer_section = build_handoff_section(ghost_id)
      {:ok, markdown <> transfer_section}
    end
  end

  # -- Private: Major --------------------------------------------------------

  defp build_major_state_summary do
    ghosts = Archive.all(:ghosts)
    active_ghosts = Enum.filter(ghosts, &(&1.status in ["working", "idle", "starting"]))

    pending_quests =
      Archive.filter(:missions, fn q -> q.status in ["pending", "active", "planning"] end)

    pending_jobs = Archive.filter(:ops, fn j -> j.status == "pending" end)
    recent_waggles = GiTF.Link.list(to: "major", limit: 10)

    planning_quests = Enum.filter(pending_quests, &(&1.status == "planning"))
    quest_specs_section = format_quest_specs(planning_quests)

    sections = [
      "---",
      "## Current GiTF State",
      "",
      "### Pending Quests (#{length(pending_quests)})",
      format_quests(pending_quests),
      "",
      quest_specs_section,
      "### Active Bees (#{length(active_ghosts)})",
      format_bees(active_ghosts),
      "",
      "### Pending Jobs (#{length(pending_jobs)})",
      format_jobs(pending_jobs),
      "",
      "### Recent Messages to Major (#{length(recent_waggles)})",
      format_waggles(recent_waggles)
    ]

    Enum.join(sections, "\n")
  end

  defp format_quests([]), do: "None."

  defp format_quests(missions) do
    missions
    |> Enum.map(fn q ->
      comb_label = resolve_comb_label(q[:sector_id])
      job_count = Archive.count(:ops, fn j -> j.mission_id == q.id end)
      line = "- **#{q.name}** (#{q.id}) [#{q.status}] — #{job_count} op(s)#{comb_label}"

      if q[:description] do
        line <> "\n  > #{q.description}"
      else
        line
      end
    end)
    |> Enum.join("\n")
  end

  defp resolve_comb_label(nil), do: ""

  defp resolve_comb_label(sector_id) do
    case Archive.get(:sectors, sector_id) do
      nil -> " | sector: #{sector_id}"
      sector -> " | sector: #{sector.name}"
    end
  end

  defp format_bees([]), do: "None."

  defp format_bees(ghosts) do
    ghosts
    |> Enum.map(fn b -> "- **#{b.name}** (#{b.id}): #{b.status}" end)
    |> Enum.join("\n")
  end

  defp format_jobs([]), do: "None."

  defp format_jobs(ops) do
    ops
    |> Enum.map(fn j -> "- **#{j.title}** (#{j.id})" end)
    |> Enum.join("\n")
  end

  defp format_waggles([]), do: "None."

  defp format_waggles(links) do
    links
    |> Enum.map(fn w ->
      read_marker = if w.read, do: "[read]", else: "[unread]"
      "- #{read_marker} From #{w.from}: #{w.subject || "(no subject)"}"
    end)
    |> Enum.join("\n")
  end

  # -- Private: Quest Specs --------------------------------------------------

  defp format_quest_specs([]), do: ""

  defp format_quest_specs(planning_quests) do
    sections =
      Enum.flat_map(planning_quests, fn mission ->
        phases = GiTF.Specs.list_phases(mission.id)

        if phases == [] do
          []
        else
          phase_sections =
            Enum.flat_map(phases, fn phase ->
              case GiTF.Specs.read(mission.id, phase) do
                {:ok, content} ->
                  truncated = truncate_spec(content, 100)
                  ["#### #{String.capitalize(phase)}", "", truncated, ""]

                {:error, _} ->
                  []
              end
            end)

          ["### Planning Specs: #{mission.name} (#{mission.id})", "" | phase_sections]
        end
      end)

    case sections do
      [] -> ""
      _ -> Enum.join(sections, "\n") <> "\n"
    end
  end

  defp truncate_spec(content, max_lines) do
    lines = String.split(content, "\n")

    if length(lines) > max_lines do
      Enum.take(lines, max_lines)
      |> Enum.join("\n")
      |> Kernel.<>("\n\n(truncated — #{length(lines) - max_lines} more lines)")
    else
      content
    end
  end

  # -- Private: Bee ----------------------------------------------------------

  defp fetch_bee(ghost_id) do
    case Archive.get(:ghosts, ghost_id) do
      nil -> {:error, :bee_not_found}
      ghost -> {:ok, ghost}
    end
  end

  defp build_bee_briefing(ghost) do
    op = fetch_job_for_bee(ghost)
    shell = fetch_cell_for_bee(ghost)
    links = GiTF.Link.list_unread(ghost.id)

    quest_context = build_quest_context(op)

    sections = [
      "# Bee Briefing: #{ghost.name} (#{ghost.id})",
      "",
      "## Your Job",
      format_job_detail(op),
      "",
      quest_context,
      "## Your Workspace",
      format_cell_detail(shell),
      "",
      "## Agent Profile",
      format_agent_section(shell),
      "",
      "## Unread Messages (#{length(links)})",
      format_waggles(links),
      "",
      "## Rules",
      "- Complete your assigned op and nothing else.",
      "- When done, send a link_msg to the queen: `gitf link send --to queen --subject \"job_complete\" --body \"<summary>\"`",
      "- If you are blocked, send: `gitf link send --to queen --subject \"job_blocked\" --body \"<reason>\"`",
      "- Do NOT modify files outside your worktree.",
      friction_rules(op)
    ]

    sections
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp fetch_job_for_bee(%{op_id: nil}), do: nil

  defp fetch_job_for_bee(%{op_id: op_id}) when is_binary(op_id) do
    Archive.get(:ops, op_id)
  end

  defp fetch_job_for_bee(_bee), do: nil

  defp fetch_cell_for_bee(ghost) do
    Archive.filter(:shells, fn c -> c.ghost_id == ghost.id and c.status == "active" end)
    |> List.first()
  end

  defp format_job_detail(nil), do: "No op assigned."

  defp format_job_detail(op) do
    lines = [
      "**#{op.title}** (#{op.id})",
      "Status: #{op.status}"
    ]

    lines =
      if op.description,
        do: lines ++ ["", op.description],
        else: lines

    Enum.join(lines, "\n")
  end

  defp format_cell_detail(nil), do: "No shell assigned."

  defp format_cell_detail(shell) do
    [
      "Path: `#{shell.worktree_path}`",
      "Branch: `#{shell.branch}`"
    ]
    |> Enum.join("\n")
  end

  defp friction_rules(nil), do: ""

  defp friction_rules(op) do
    risk_level = Map.get(op, :risk_level, :low)
    GiTF.Ghost.Limiter.friction_instructions(risk_level)
  end

  # -- Private: Quest Context ------------------------------------------------

  defp build_quest_context(nil), do: ""

  defp build_quest_context(op) do
    # Only enrich non-phase implementation ops
    if Map.get(op, :phase_job, false) do
      ""
    else
      mission = Archive.get(:missions, op.mission_id)

      if is_nil(mission) or is_nil(Map.get(mission, :artifacts)) or map_size(Map.get(mission, :artifacts, %{})) == 0 do
        ""
      else
        sections = []
        artifacts = mission.artifacts

        # Add relevant requirements
        sections =
          case Map.get(artifacts, "requirements") do
            nil ->
              sections

            reqs ->
              func_reqs = Map.get(reqs, "functional_requirements", [])

              formatted =
                Enum.map_join(func_reqs, "\n", fn req ->
                  criteria = Map.get(req, "acceptance_criteria", [])
                  criteria_str = Enum.map_join(criteria, "\n", &("    - #{&1}"))
                  "- **#{Map.get(req, "id", "?")}**: #{Map.get(req, "description", "")}\n#{criteria_str}"
                end)

              sections ++ ["## Requirements\n", formatted, ""]
          end

        # Add relevant design section
        sections =
          case Map.get(artifacts, "design") do
            nil ->
              sections

            design ->
              relevant = extract_relevant_design(design, op)
              sections ++ ["## Technical Design\n", relevant, ""]
          end

        # Add this op's acceptance criteria
        sections =
          case Map.get(op, :acceptance_criteria, []) do
            [] ->
              sections

            criteria ->
              formatted = Enum.map_join(criteria, "\n", &("- [ ] #{&1}"))
              sections ++ ["## Acceptance Criteria (Your Job)\n", formatted, ""]
          end

        Enum.join(sections, "\n")
      end
    end
  end

  defp extract_relevant_design(design, op) do
    target_files = Map.get(op, :target_files, [])
    components = Map.get(design, "components", [])

    relevant =
      if target_files == [] do
        components
      else
        Enum.filter(components, fn comp ->
          comp_files = Map.get(comp, "files", [])
          Enum.any?(comp_files, fn f -> f in target_files end)
        end)
      end

    relevant = if relevant == [], do: components, else: relevant

    Enum.map_join(relevant, "\n", fn comp ->
      files = Map.get(comp, "files", []) |> Enum.join(", ")
      "- **#{Map.get(comp, "name", "?")}**: #{Map.get(comp, "description", "")} (#{files})"
    end)
  end

  # -- Private: Agent Profile ------------------------------------------------

  defp format_agent_section(nil), do: "No workspace -- cannot check agents."

  defp format_agent_section(shell) do
    sector_path = get_comb_path(shell.sector_id)

    case sector_path do
      nil ->
        "No sector path available."

      path ->
        agents = GiTF.AgentProfile.list_agents(path)

        case agents do
          [] -> "No agent profiles configured for this sector."
          list -> Enum.map(list, fn a -> "- #{a}" end) |> Enum.join("\n")
        end
    end
  end

  defp get_comb_path(nil), do: nil

  defp get_comb_path(sector_id) do
    case Archive.get(:sectors, sector_id) do
      nil -> nil
      sector -> sector.path
    end
  end

  # -- Private: Transfer ------------------------------------------------------

  defp build_handoff_section(ghost_id) do
    case GiTF.Transfer.detect_handoff(ghost_id) do
      {:ok, link_msg} ->
        case GiTF.Transfer.resume(ghost_id, link_msg.id) do
          {:ok, briefing} ->
            "\n\n---\n\n" <> briefing

          {:error, _} ->
            ""
        end

      {:error, :no_handoff} ->
        ""
    end
  end
end
