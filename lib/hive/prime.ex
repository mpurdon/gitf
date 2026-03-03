defmodule Hive.Prime do
  @moduledoc """
  Generates context prompts for Claude Code sessions.

  Priming is the act of feeding Claude its initial context at session start.
  The Queen gets the QUEEN.md instructions plus a snapshot of the current
  hive state. A Bee gets its specific job description, relevant waggles,
  and information about the comb it is working on.

  Output is Markdown text, ready for Claude to parse.
  """

  alias Hive.Store

  # -- Public API ------------------------------------------------------------

  @doc """
  Primes a Queen or Bee with context for a Claude Code session.

  - `prime(:queen, hive_root)` reads QUEEN.md and appends current hive state
  - `prime(:bee, bee_id)` builds a briefing from the bee's job, cell, and waggles

  Returns `{:ok, markdown}` or `{:error, reason}`.
  """
  @spec prime(:queen | :bee, String.t()) :: {:ok, String.t()} | {:error, term()}
  def prime(role, identifier)

  def prime(:queen, hive_root) do
    queen_md_path = Path.join([hive_root, ".hive", "queen", "QUEEN.md"])

    with {:ok, instructions} <- File.read(queen_md_path) do
      state_summary = build_queen_state_summary()
      {:ok, instructions <> "\n\n" <> state_summary}
    end
  end

  def prime(:bee, bee_id) do
    with {:ok, bee} <- fetch_bee(bee_id) do
      markdown = build_bee_briefing(bee)
      handoff_section = build_handoff_section(bee_id)
      {:ok, markdown <> handoff_section}
    end
  end

  # -- Private: Queen --------------------------------------------------------

  defp build_queen_state_summary do
    bees = Store.all(:bees)
    active_bees = Enum.filter(bees, &(&1.status in ["working", "idle", "starting"]))

    pending_quests =
      Store.filter(:quests, fn q -> q.status in ["pending", "active", "planning"] end)

    pending_jobs = Store.filter(:jobs, fn j -> j.status == "pending" end)
    recent_waggles = Hive.Waggle.list(to: "queen", limit: 10)

    planning_quests = Enum.filter(pending_quests, &(&1.status == "planning"))
    quest_specs_section = format_quest_specs(planning_quests)

    sections = [
      "---",
      "## Current Hive State",
      "",
      "### Pending Quests (#{length(pending_quests)})",
      format_quests(pending_quests),
      "",
      quest_specs_section,
      "### Active Bees (#{length(active_bees)})",
      format_bees(active_bees),
      "",
      "### Pending Jobs (#{length(pending_jobs)})",
      format_jobs(pending_jobs),
      "",
      "### Recent Messages to Queen (#{length(recent_waggles)})",
      format_waggles(recent_waggles)
    ]

    Enum.join(sections, "\n")
  end

  defp format_quests([]), do: "None."

  defp format_quests(quests) do
    quests
    |> Enum.map(fn q ->
      comb_label = resolve_comb_label(q[:comb_id])
      job_count = Store.count(:jobs, fn j -> j.quest_id == q.id end)
      line = "- **#{q.name}** (#{q.id}) [#{q.status}] — #{job_count} job(s)#{comb_label}"

      if q[:description] do
        line <> "\n  > #{q.description}"
      else
        line
      end
    end)
    |> Enum.join("\n")
  end

  defp resolve_comb_label(nil), do: ""

  defp resolve_comb_label(comb_id) do
    case Store.get(:combs, comb_id) do
      nil -> " | comb: #{comb_id}"
      comb -> " | comb: #{comb.name}"
    end
  end

  defp format_bees([]), do: "None."

  defp format_bees(bees) do
    bees
    |> Enum.map(fn b -> "- **#{b.name}** (#{b.id}): #{b.status}" end)
    |> Enum.join("\n")
  end

  defp format_jobs([]), do: "None."

  defp format_jobs(jobs) do
    jobs
    |> Enum.map(fn j -> "- **#{j.title}** (#{j.id})" end)
    |> Enum.join("\n")
  end

  defp format_waggles([]), do: "None."

  defp format_waggles(waggles) do
    waggles
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
      Enum.flat_map(planning_quests, fn quest ->
        phases = Hive.Specs.list_phases(quest.id)

        if phases == [] do
          []
        else
          phase_sections =
            Enum.flat_map(phases, fn phase ->
              case Hive.Specs.read(quest.id, phase) do
                {:ok, content} ->
                  truncated = truncate_spec(content, 100)
                  ["#### #{String.capitalize(phase)}", "", truncated, ""]

                {:error, _} ->
                  []
              end
            end)

          ["### Planning Specs: #{quest.name} (#{quest.id})", "" | phase_sections]
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

  defp fetch_bee(bee_id) do
    case Store.get(:bees, bee_id) do
      nil -> {:error, :bee_not_found}
      bee -> {:ok, bee}
    end
  end

  defp build_bee_briefing(bee) do
    job = fetch_job_for_bee(bee)
    cell = fetch_cell_for_bee(bee)
    waggles = Hive.Waggle.list_unread(bee.id)

    quest_context = build_quest_context(job)

    sections = [
      "# Bee Briefing: #{bee.name} (#{bee.id})",
      "",
      "## Your Job",
      format_job_detail(job),
      "",
      quest_context,
      "## Your Workspace",
      format_cell_detail(cell),
      "",
      "## Agent Profile",
      format_agent_section(cell),
      "",
      "## Unread Messages (#{length(waggles)})",
      format_waggles(waggles),
      "",
      "## Rules",
      "- Complete your assigned job and nothing else.",
      "- When done, send a waggle to the queen: `hive waggle send --to queen --subject \"job_complete\" --body \"<summary>\"`",
      "- If you are blocked, send: `hive waggle send --to queen --subject \"job_blocked\" --body \"<reason>\"`",
      "- Do NOT modify files outside your worktree.",
      friction_rules(job)
    ]

    sections
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp fetch_job_for_bee(%{job_id: nil}), do: nil

  defp fetch_job_for_bee(%{job_id: job_id}) when is_binary(job_id) do
    Store.get(:jobs, job_id)
  end

  defp fetch_job_for_bee(_bee), do: nil

  defp fetch_cell_for_bee(bee) do
    Store.filter(:cells, fn c -> c.bee_id == bee.id and c.status == "active" end)
    |> List.first()
  end

  defp format_job_detail(nil), do: "No job assigned."

  defp format_job_detail(job) do
    lines = [
      "**#{job.title}** (#{job.id})",
      "Status: #{job.status}"
    ]

    lines =
      if job.description,
        do: lines ++ ["", job.description],
        else: lines

    Enum.join(lines, "\n")
  end

  defp format_cell_detail(nil), do: "No cell assigned."

  defp format_cell_detail(cell) do
    [
      "Path: `#{cell.worktree_path}`",
      "Branch: `#{cell.branch}`"
    ]
    |> Enum.join("\n")
  end

  defp friction_rules(nil), do: ""

  defp friction_rules(job) do
    risk_level = Map.get(job, :risk_level, :low)
    Hive.Bee.CognitiveFriction.friction_instructions(risk_level)
  end

  # -- Private: Quest Context ------------------------------------------------

  defp build_quest_context(nil), do: ""

  defp build_quest_context(job) do
    # Only enrich non-phase implementation jobs
    if Map.get(job, :phase_job, false) do
      ""
    else
      quest = Store.get(:quests, job.quest_id)

      if is_nil(quest) or is_nil(Map.get(quest, :artifacts)) or map_size(Map.get(quest, :artifacts, %{})) == 0 do
        ""
      else
        sections = []
        artifacts = quest.artifacts

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
              relevant = extract_relevant_design(design, job)
              sections ++ ["## Technical Design\n", relevant, ""]
          end

        # Add this job's acceptance criteria
        sections =
          case Map.get(job, :acceptance_criteria, []) do
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

  defp extract_relevant_design(design, job) do
    target_files = Map.get(job, :target_files, [])
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

  defp format_agent_section(cell) do
    comb_path = get_comb_path(cell.comb_id)

    case comb_path do
      nil ->
        "No comb path available."

      path ->
        agents = Hive.AgentProfile.list_agents(path)

        case agents do
          [] -> "No agent profiles configured for this comb."
          list -> Enum.map(list, fn a -> "- #{a}" end) |> Enum.join("\n")
        end
    end
  end

  defp get_comb_path(nil), do: nil

  defp get_comb_path(comb_id) do
    case Store.get(:combs, comb_id) do
      nil -> nil
      comb -> comb.path
    end
  end

  # -- Private: Handoff ------------------------------------------------------

  defp build_handoff_section(bee_id) do
    case Hive.Handoff.detect_handoff(bee_id) do
      {:ok, waggle} ->
        case Hive.Handoff.resume(bee_id, waggle.id) do
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
