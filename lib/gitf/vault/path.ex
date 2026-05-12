defmodule GiTF.Vault.Path do
  @moduledoc """
  Pure path computation for the Obsidian vault.

  The vault layout is disk-canonical: the markdown files on disk are the
  source of truth, the Archive holds a derived index. Every file path we
  read or write goes through this module so the layout is consistent and
  testable in isolation.

  ## Layout

      <vault_root>/
      ├── README.md
      ├── Daily Notes/<YYYY-MM-DD>.md
      ├── Sectors/<sector_id>/
      │   ├── 001_index.md
      │   ├── 002_kanban.md
      │   ├── Missions/<mission_id>-<slug>.md
      │   ├── Pages/<slug>.md
      │   └── Indexes/<NNN>_<name>.md
      ├── Ghosts/<ghost_name>.md
      └── Templates/<template_name>.md

  Numeric prefixes (`001_`, `002_`) are used for files whose ordering
  matters in the Obsidian sidebar (sector index, kanban, curated indexes).
  Pages/Missions/Daily Notes order naturally by alphabetical slug or ISO
  date and don't need prefixes.
  """

  @vault_subdir "vault"

  @doc """
  Returns the vault root directory for the given gitf root.

      iex> GiTF.Vault.Path.vault_root("/tmp/gitf")
      "/tmp/gitf/vault"
  """
  @spec vault_root(String.t()) :: String.t()
  def vault_root(gitf_root) when is_binary(gitf_root) do
    Path.join(gitf_root, @vault_subdir)
  end

  @doc "Daily Notes directory."
  @spec daily_notes_dir(String.t()) :: String.t()
  def daily_notes_dir(gitf_root), do: Path.join(vault_root(gitf_root), "Daily Notes")

  @doc "Sectors directory."
  @spec sectors_dir(String.t()) :: String.t()
  def sectors_dir(gitf_root), do: Path.join(vault_root(gitf_root), "Sectors")

  @doc "Ghosts (employee directory) directory."
  @spec ghosts_dir(String.t()) :: String.t()
  def ghosts_dir(gitf_root), do: Path.join(vault_root(gitf_root), "Ghosts")

  @doc "Templates directory."
  @spec templates_dir(String.t()) :: String.t()
  def templates_dir(gitf_root), do: Path.join(vault_root(gitf_root), "Templates")

  @doc "Per-sector directory for `sector_id`."
  @spec sector_dir(String.t(), String.t()) :: String.t()
  def sector_dir(gitf_root, sector_id) do
    Path.join(sectors_dir(gitf_root), sanitize_segment(sector_id))
  end

  @doc "Per-sector Pages directory."
  @spec pages_dir(String.t(), String.t()) :: String.t()
  def pages_dir(gitf_root, sector_id), do: Path.join(sector_dir(gitf_root, sector_id), "Pages")

  @doc "Per-sector Missions directory."
  @spec missions_dir(String.t(), String.t()) :: String.t()
  def missions_dir(gitf_root, sector_id), do: Path.join(sector_dir(gitf_root, sector_id), "Missions")

  @doc "Per-sector Indexes directory."
  @spec indexes_dir(String.t(), String.t()) :: String.t()
  def indexes_dir(gitf_root, sector_id), do: Path.join(sector_dir(gitf_root, sector_id), "Indexes")

  @doc "Global pages directory (cross-sector concepts)."
  @spec global_pages_dir(String.t()) :: String.t()
  def global_pages_dir(gitf_root), do: Path.join([sectors_dir(gitf_root), "_global", "Pages"])

  @doc """
  Page file path for `slug` in `sector_id` (or global when `sector_id` is nil).

      iex> GiTF.Vault.Path.page_file("/tmp/gitf", "frontend", "auth-flow")
      "/tmp/gitf/vault/Sectors/frontend/Pages/auth-flow.md"
  """
  @spec page_file(String.t(), String.t() | nil, String.t()) :: String.t()
  def page_file(gitf_root, nil, slug) do
    Path.join(global_pages_dir(gitf_root), "#{sanitize_segment(slug)}.md")
  end

  def page_file(gitf_root, sector_id, slug) do
    Path.join(pages_dir(gitf_root, sector_id), "#{sanitize_segment(slug)}.md")
  end

  @doc """
  Mission file path. Filename is `<mission_id>-<slugified-title>.md`.

      iex> GiTF.Vault.Path.mission_file("/tmp/gitf", "frontend", "msn-abc", "Fix login flow")
      "/tmp/gitf/vault/Sectors/frontend/Missions/msn-abc-fix-login-flow.md"
  """
  @spec mission_file(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def mission_file(gitf_root, sector_id, mission_id, title) do
    name = "#{mission_id}-#{slugify(title)}"
    Path.join(missions_dir(gitf_root, sector_id), "#{name}.md")
  end

  @doc "Sector index file path (`001_index.md`)."
  @spec sector_index_file(String.t(), String.t()) :: String.t()
  def sector_index_file(gitf_root, sector_id) do
    Path.join(sector_dir(gitf_root, sector_id), "001_index.md")
  end

  @doc """
  Filename base (no extension) for a mission file under `Missions/`.

  Used by renderers building wikilinks back to the mission file:
  `[[<mission_id>-<slugified-title>]]`. Falls back to bare `mission_id`
  when title is blank.
  """
  @spec mission_file_base(map()) :: String.t()
  def mission_file_base(mission) when is_map(mission) do
    id = mission[:id] || mission["id"] || ""
    title = mission[:name] || mission[:goal] || mission["name"] || mission["goal"] || ""
    slug = slugify(title)
    if slug == "", do: to_string(id), else: "#{id}-#{slug}"
  end

  @doc "Sector kanban file path (`002_kanban.md`)."
  @spec sector_kanban_file(String.t(), String.t()) :: String.t()
  def sector_kanban_file(gitf_root, sector_id) do
    Path.join(sector_dir(gitf_root, sector_id), "002_kanban.md")
  end

  @doc "Index file path inside a sector (`<NNN>_<name>.md`)."
  @spec index_file(String.t(), String.t(), pos_integer(), String.t()) :: String.t()
  def index_file(gitf_root, sector_id, position, name)
      when is_integer(position) and position > 0 and is_binary(name) do
    prefix = position |> Integer.to_string() |> String.pad_leading(3, "0")
    filename = "#{prefix}_#{sanitize_segment(name)}.md"
    Path.join(indexes_dir(gitf_root, sector_id), filename)
  end

  @doc "Daily note file path for `date` (Date or ISO8601 string)."
  @spec daily_note_file(String.t(), Date.t() | String.t()) :: String.t()
  def daily_note_file(gitf_root, %Date{} = date) do
    daily_note_file(gitf_root, Date.to_iso8601(date))
  end

  def daily_note_file(gitf_root, date) when is_binary(date) do
    Path.join(daily_notes_dir(gitf_root), "#{date}.md")
  end

  @doc "Ghost profile file path for `ghost_name`."
  @spec ghost_file(String.t(), String.t()) :: String.t()
  def ghost_file(gitf_root, ghost_name) do
    Path.join(ghosts_dir(gitf_root), "#{sanitize_segment(ghost_name)}.md")
  end

  @doc """
  Slugifies a free-form string into a filename-safe form.

  Lowercase, alphanumerics + hyphens only, collapses runs of whitespace
  and punctuation to a single hyphen, trims leading/trailing hyphens.

      iex> GiTF.Vault.Path.slugify("Fix Login Flow on Safari iOS!")
      "fix-login-flow-on-safari-ios"

      iex> GiTF.Vault.Path.slugify("API/Auth — endpoints")
      "api-auth-endpoints"
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[^\x00-\x7f]/u, "")
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  # Strict sanitiser for path segments we use as-is (sector_id, ghost_name,
  # already-slugified inputs). Rejects `..` runs and empty results so a
  # caller can't accidentally produce a segment that escapes its parent.
  @doc false
  @spec sanitize_segment(String.t()) :: String.t()
  def sanitize_segment(segment) when is_binary(segment) do
    cleaned =
      segment
      |> String.replace(~r/[\/\\\0]/, "-")
      |> String.replace(~r/\.\.+/, "-")
      |> String.replace(~r/^\.+/, "")
      |> String.trim()

    if cleaned == "", do: "_", else: cleaned
  end
end
