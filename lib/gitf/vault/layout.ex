defmodule GiTF.Vault.Layout do
  @moduledoc """
  Initializes the on-disk vault layout when a sector is added or when the
  Factory boots for the first time.

  Idempotent — safe to re-run. We never overwrite existing files (operator
  may have edited them). Anything we'd seed is created with `File.write/2`
  via `GiTF.Vault.File.write/2` only when the target file does not exist.

  ## What gets created

  When a new sector `<id>` is registered:

      <vault_root>/Sectors/<id>/001_index.md
      <vault_root>/Sectors/<id>/002_kanban.md
      <vault_root>/Sectors/<id>/Pages/.gitkeep
      <vault_root>/Sectors/<id>/Indexes/.gitkeep
      <vault_root>/Sectors/<id>/Missions/.gitkeep

  Plus the global vault scaffold (one-time):

      <vault_root>/README.md
      <vault_root>/Daily Notes/.gitkeep
      <vault_root>/Ghosts/.gitkeep
      <vault_root>/Sectors/_global/Pages/.gitkeep
      <vault_root>/Templates/{Daily Note,Mission,Page,Ghost Profile,Sector Index}.md
  """

  require Logger

  alias GiTF.Vault.File, as: VFile
  alias GiTF.Vault.Path, as: VPath

  @doc """
  Ensures the global vault scaffold exists. Idempotent.

  Returns `:ok` regardless — vault setup is best-effort and must not
  block sector registration.
  """
  @spec init_vault(String.t()) :: :ok
  def init_vault(gitf_root) when is_binary(gitf_root) do
    write_if_missing(Path.join(VPath.vault_root(gitf_root), "README.md"), readme_body())

    Enum.each(
      [
        VPath.daily_notes_dir(gitf_root),
        VPath.ghosts_dir(gitf_root),
        VPath.global_pages_dir(gitf_root)
      ],
      &ensure_dir/1
    )

    seed_templates(gitf_root)
    :ok
  rescue
    e ->
      Logger.warning("Vault.Layout init_vault failed: #{Exception.message(e)}")
      :ok
  end

  @doc """
  Ensures the per-sector folder structure exists, seeded with empty
  index and kanban files. Idempotent.
  """
  @spec init_sector(String.t(), %{required(:id) => String.t()} | map()) :: :ok
  def init_sector(gitf_root, sector) when is_map(sector) do
    sector_id = sector[:id] || sector["id"]

    if is_binary(sector_id) and sector_id != "" do
      init_vault(gitf_root)

      Enum.each(
        [
          VPath.sector_dir(gitf_root, sector_id),
          VPath.pages_dir(gitf_root, sector_id),
          VPath.indexes_dir(gitf_root, sector_id),
          VPath.missions_dir(gitf_root, sector_id)
        ],
        &ensure_dir/1
      )

      write_if_missing(VPath.sector_index_file(gitf_root, sector_id), sector_index_body(sector))

      write_if_missing(
        VPath.sector_kanban_file(gitf_root, sector_id),
        empty_kanban_body(sector_id)
      )
    end

    :ok
  rescue
    e ->
      Logger.warning("Vault.Layout init_sector failed: #{Exception.message(e)}")
      :ok
  end

  # -- Private ---------------------------------------------------------------

  defp ensure_dir(path) do
    File.mkdir_p!(path)
    File.write!(Path.join(path, ".gitkeep"), "")
  rescue
    _ -> :ok
  end

  defp write_if_missing(path, body) do
    if VFile.exists?(path) do
      :ok
    else
      case VFile.write(path, body) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("Vault.Layout write #{path} failed: #{inspect(reason)}")
      end
    end
  end

  defp readme_body do
    """
    # GiTF Vault

    This folder is your Obsidian-readable view of the Factory. Open it as a
    vault in Obsidian and you'll see:

    - **Daily Notes/** — the Major's standup written nightly
    - **Sectors/** — one folder per project sector
        - `001_index.md` — sector overview
        - `002_kanban.md` — Obsidian Kanban board of missions
        - `Missions/` — one file per mission, double as kanban cards
        - `Pages/` — wiki entity pages, the AI-maintained knowledge base
        - `Indexes/` — curated TOCs (numbered for ordering)
    - **Ghosts/** — employee directory; one file per ghost worker
    - **Templates/** — file templates the Factory uses on first render

    The Factory writes to this folder. You can edit `Pages/` and `Indexes/`
    in Obsidian — your edits are detected via content hash and the Factory
    re-embeds them on next read. Mission files and the kanban are
    rewritten on phase changes; operator edits to those will be overwritten
    until the M3 bidirectional control plane lands.
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp sector_index_body(sector) do
    name = sector[:name] || sector[:id] || "sector"

    """
    ---
    sector_id: #{sector[:id]}
    name: "#{name}"
    ---

    # #{name}

    > Sector overview. Edit this file in Obsidian — the Factory does not
    > overwrite it. Use it as the operator's notebook for this project:
    > goals, constraints, links to relevant pages and indexes.

    ## Goals

    -

    ## Constraints

    -

    ## Indexes

    See `Indexes/` for curated TOCs.

    ## Pages

    See `Pages/` for wiki entity pages.

    ## Active missions

    See [[002_kanban]].
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp empty_kanban_body(sector_id) do
    GiTF.Vault.Renderer.Kanban.render(sector_id, [])
  end

  defp seed_templates(gitf_root) do
    templates_dir = VPath.templates_dir(gitf_root)
    File.mkdir_p!(templates_dir)

    [
      {"Daily Note.md", template_daily_note()},
      {"Mission.md", template_mission()},
      {"Page.md", template_page()},
      {"Ghost Profile.md", template_ghost()},
      {"Sector Index.md", template_sector_index()},
      {"Index.md", template_index()}
    ]
    |> Enum.each(fn {filename, body} ->
      write_if_missing(Path.join(templates_dir, filename), body)
    end)
  end

  defp template_daily_note do
    """
    ---
    date: {{date}}
    missions_in_flight: 0
    missions_merged_today: 0
    missions_failed_today: 0
    ---

    # {{date}} — Standup

    ## Yesterday

    -

    ## Today

    -

    ## Active employees

    -

    ## Sectors

    -

    ## Costs

    Today $0.00 · This week $0.00
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp template_mission do
    """
    ---
    mission_id: ""
    sector: ""
    status: pending
    phase: pending
    priority: normal
    goal: ""
    ---

    # {{title}}

    ## Goal

    {{goal}}

    ## Phases

    - [ ] research
    - [ ] requirements
    - [ ] design
    - [ ] review
    - [ ] planning
    - [ ] implementation
    - [ ] validation
    - [ ] sync
    - [ ] simplify
    - [ ] publish
    - [ ] scoring

    ## Activity

    -

    ## Linked

    -
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp template_page do
    """
    ---
    slug: "{{slug}}"
    sector: ""
    tags: []
    ---

    # {{title}}

    Brief one-liner that summarises the entity (used as a gloss in
    semantic search results — the first non-heading sentence).

    ## Details

    Body of the page. Use [[other-slug]] to link to related pages — the
    Factory maintains reciprocal `links_in` automatically on save.
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp template_ghost do
    """
    ---
    name: ""
    ghost_id: ""
    model: ""
    tier: ""
    status: ""
    sector: ""
    hired_at: ""
    missions_completed: 0
    ---

    # {{name}}

    ## Specialties

    -

    ## Recent

    -
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp template_sector_index do
    """
    ---
    sector_id: ""
    name: ""
    ---

    # {{name}}

    > Operator notebook for this sector. Edit freely — the Factory does
    > not overwrite this file.

    ## Goals

    -

    ## Constraints

    -

    ## Indexes

    See `Indexes/`.

    ## Pages

    See `Pages/`.

    ## Active missions

    See [[002_kanban]].
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp template_index do
    """
    # {{name}}

    Curated table-of-contents for this sector. Each entry is a
    `[[slug]]` reference plus an optional gloss. The Factory parses
    these into structured entries for the `knowledge_index` MCP tool.

    ## Entries

    - [[example-slug]] — short gloss explaining what this points at
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end
end
