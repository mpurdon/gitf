defmodule GiTF.Vault.Renderer.Ghost do
  @moduledoc """
  Renders a ghost's "employee profile" page.

  A ghost is the Factory's worker abstraction — supervised process with a
  model assignment, a tier, an op queue, a trust score. We surface it in
  Obsidian as a plain markdown file so the operator can browse the
  Ghosts/ directory like a directory of employees.

  Pure: takes a ghost record (and an optional list of recent missions
  the ghost worked on) and returns markdown including frontmatter.
  """

  @doc """
  Renders `ghost` to a complete markdown document.

  Optional `opts`:
    * `:recent_missions` — list of mission maps the ghost has worked on,
      newest first. Each rendered as a `[[mission-file-base]]` wikilink
      with status.
    * `:trust_score` — float; rendered in frontmatter when present.
  """
  @spec render(map(), keyword()) :: String.t()
  def render(ghost, opts \\ []) when is_map(ghost) do
    recent = Keyword.get(opts, :recent_missions, [])
    trust = Keyword.get(opts, :trust_score, ghost[:trust_score])

    [
      frontmatter(ghost, trust),
      "",
      "# #{ghost[:name] || ghost[:id]}",
      specialties_section(ghost),
      recent_section(recent)
    ]
    |> Enum.reject(&(&1 == "" or is_nil(&1)))
    |> Enum.intersperse("\n")
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  # -- Sections --------------------------------------------------------------

  defp frontmatter(g, trust) do
    GiTF.Vault.YAML.frontmatter([
      {"name", GiTF.Vault.YAML.quote_str(g[:name] || g[:id])},
      {"ghost_id", GiTF.Vault.YAML.quote_str(g[:id])},
      {"model", GiTF.Vault.YAML.quote_str(g[:model])},
      {"tier", GiTF.Vault.YAML.quote_str(g[:tier])},
      {"status", GiTF.Vault.YAML.quote_str(g[:status])},
      {"current_op", GiTF.Vault.YAML.quote_str(g[:op_id] || g[:current_op])},
      {"sector", GiTF.Vault.YAML.quote_str(g[:sector_id])},
      {"hired_at", GiTF.Vault.YAML.iso(g[:hired_at] || g[:inserted_at])},
      {"missions_completed", g[:missions_completed]},
      {"trust_score", format_trust(trust)}
    ])
  end

  defp specialties_section(g) do
    case g[:specialties] do
      [_ | _] = list ->
        items = list |> Enum.map(&"- #{&1}") |> Enum.join("\n")
        "\n## Specialties\n\n#{items}"

      _ ->
        ""
    end
  end

  defp recent_section([]), do: ""

  defp recent_section(missions) when is_list(missions) do
    items =
      missions
      |> Enum.map(fn m ->
        base = mission_file_base(m)
        status = m[:status] || "?"
        "- [[#{base}]] · #{status}"
      end)
      |> Enum.join("\n")

    "\n## Recent\n\n#{items}"
  end

  # -- Helpers ---------------------------------------------------------------

  defp format_trust(nil), do: "null"
  defp format_trust(t) when is_float(t), do: :erlang.float_to_binary(t, decimals: 2)
  defp format_trust(t), do: to_string(t)

  defp mission_file_base(m), do: GiTF.Vault.Path.mission_file_base(m)
end
