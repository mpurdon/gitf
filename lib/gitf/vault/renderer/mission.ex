defmodule GiTF.Vault.Renderer.Mission do
  @moduledoc """
  Renders a mission record into the markdown body for its vault file.

  Pure: takes a mission map (and optionally extra context like the sector
  display name) and returns the full markdown including YAML frontmatter.

  The structure is tuned for human reading in Obsidian:

  - YAML frontmatter for Dataview / Bases queries.
  - One H1 with the mission name.
  - A Phases checklist where each phase is marked `[x]` (done),
    `[~]` (running, the conventional Obsidian "in-progress" mark), or
    `[ ]` (pending) based on the orchestrator's `@phases` order.
  - An Activity section with timestamped wikilinks back to the people
    (ghosts) and source events involved.
  - A Linked section for related wiki pages — mostly populated by
    `Knowledge.Compile` later; for M2 we surface only what the mission
    record itself references.
  """

  @phases ~w(
    triage research requirements design review planning implementation
    validation awaiting_input awaiting_approval sync simplify publish scoring
  )

  @doc "Returns the canonical phase order used to render the checklist."
  @spec phases() :: [String.t()]
  def phases, do: @phases

  @doc """
  Renders `mission` to a complete markdown document.

  Optional `opts`:
    * `:activity` — list of `%{at: DateTime, text: String}` events,
      newest first; rendered under "Activity"
    * `:linked` — list of `[[slug]]` strings, rendered under "Linked"
  """
  @spec render(map(), keyword()) :: String.t()
  def render(mission, opts \\ []) when is_map(mission) do
    activity = Keyword.get(opts, :activity, [])
    linked = Keyword.get(opts, :linked, [])

    [
      frontmatter(mission),
      "",
      "# #{title(mission)}",
      "",
      goal_section(mission),
      "",
      phases_section(mission),
      activity_section(activity),
      linked_section(linked)
    ]
    |> Enum.reject(&(&1 == "" or is_nil(&1)))
    |> Enum.intersperse("\n")
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  # -- Sections --------------------------------------------------------------

  defp frontmatter(m) do
    base =
      GiTF.Vault.YAML.frontmatter([
        {"mission_id", GiTF.Vault.YAML.quote_str(m[:id])},
        {"sector", GiTF.Vault.YAML.quote_str(m[:sector_id])},
        {"status", GiTF.Vault.YAML.quote_str(m[:status])},
        {"phase", GiTF.Vault.YAML.quote_str(m[:current_phase])},
        {"priority", priority_str(m[:priority])},
        {"goal", GiTF.Vault.YAML.quote_str(short(m[:goal], 200))},
        {"created_at", GiTF.Vault.YAML.iso(m[:inserted_at])},
        {"updated_at", GiTF.Vault.YAML.iso(m[:updated_at])}
      ])

    case issue_ref_yaml(m[:issue_ref]) do
      "" -> base
      block -> String.trim_trailing(base, "\n---") <> block <> "\n---"
    end
  end

  defp issue_ref_yaml(ref) when is_map(ref) and map_size(ref) > 0 do
    lines =
      ref
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.map(fn {k, v} -> "  #{k}: #{GiTF.Vault.YAML.quote_str(v)}" end)
      |> Enum.join("\n")

    "\nissue_ref:\n" <> lines
  end

  defp issue_ref_yaml(_), do: ""

  defp title(m), do: m[:name] || short(m[:goal] || "Mission", 80) || "Mission"

  defp goal_section(m) do
    case m[:goal] do
      nil -> ""
      "" -> ""
      goal -> "## Goal\n\n#{String.trim(to_string(goal))}"
    end
  end

  defp phases_section(m) do
    current = to_string(m[:current_phase] || "")
    current_index = Enum.find_index(@phases, &(&1 == current))

    items =
      @phases
      |> Enum.with_index()
      |> Enum.map(fn {phase, idx} ->
        mark = phase_mark(idx, current_index, m[:status])
        suffix = phase_suffix(phase, m)
        "- [#{mark}] #{phase}#{suffix}"
      end)
      |> Enum.join("\n")

    "## Phases\n\n#{items}"
  end

  defp phase_mark(_idx, nil, status) when status in ["completed", "merged"], do: "x"
  defp phase_mark(_idx, nil, _status), do: " "

  defp phase_mark(idx, current, status)
       when status in ["completed", "merged"] and idx <= current,
       do: "x"

  defp phase_mark(idx, current, _status) when idx < current, do: "x"
  defp phase_mark(idx, current, _status) when idx == current, do: "~"
  defp phase_mark(_idx, _current, _status), do: " "

  defp phase_suffix(phase, m) do
    case get_in(m, [:phase_jobs, phase]) do
      %{started_at: %DateTime{} = t} -> " · started #{format_time(t)}"
      %{ghost_id: gid} when is_binary(gid) -> " · [[#{gid}]]"
      _ -> ""
    end
  end

  defp activity_section([]), do: ""

  defp activity_section(events) when is_list(events) do
    items =
      events
      |> Enum.map(fn e ->
        ts = format_time(e[:at] || e["at"])
        text = e[:text] || e["text"] || ""
        "- #{ts} — #{text}"
      end)
      |> Enum.join("\n")

    "\n## Activity\n\n#{items}"
  end

  defp linked_section([]), do: ""

  defp linked_section(slugs) when is_list(slugs) do
    items =
      slugs
      |> Enum.uniq()
      |> Enum.map(fn s -> "- [[#{s}]]" end)
      |> Enum.join("\n")

    "\n## Linked\n\n#{items}"
  end

  # -- Helpers ---------------------------------------------------------------

  defp priority_str(nil), do: "null"
  defp priority_str(p) when is_atom(p), do: Atom.to_string(p)
  defp priority_str(p), do: to_string(p)

  defp short(nil, _), do: nil
  defp short(s, n) when is_binary(s) and byte_size(s) <= n, do: s
  defp short(s, n) when is_binary(s), do: String.slice(s, 0, n) <> "…"
  defp short(_, _), do: nil

  defp format_time(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp format_time(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> DateTime.to_iso8601(dt)
      _ -> s
    end
  end

  defp format_time(_), do: "?"
end
