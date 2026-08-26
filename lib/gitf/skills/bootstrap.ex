defmodule GiTF.Skills.Bootstrap do
  @moduledoc """
  Seeds the `:skills` collection with hand-authored global skills shipped
  in `priv/skills/*.md`.

  Runs at application start under `GiTF.Application.deferred_init/0`. Each
  skill file is parsed (YAML frontmatter + body) and inserted as a
  `:global, source: :human` skill. Existing skills with the same `name`
  are NOT overwritten — operator edits or refined versions in the Archive
  win over the seed copy.

  This is best-effort: a malformed file logs a warning and is skipped.
  Bootstrap failures must never block app startup.
  """

  require Logger

  alias GiTF.Skills

  @doc """
  Loads all `priv/skills/*.md` files into the `:skills` collection.
  Returns `{loaded, skipped}` counts.
  """
  @spec seed_global_skills() :: {non_neg_integer(), non_neg_integer()}
  def seed_global_skills do
    skills_dir = priv_skills_dir()

    case File.ls(skills_dir) do
      {:ok, files} ->
        # Snapshot existing names ONCE so we don't re-scan Skills.all/0 per file.
        existing_names = MapSet.new(Skills.all(), & &1.name)

        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&Path.join(skills_dir, &1))
        |> Enum.reduce({0, 0}, fn path, {loaded, skipped} ->
          case load_one(path, existing_names) do
            :loaded -> {loaded + 1, skipped}
            :skipped -> {loaded, skipped + 1}
            :error -> {loaded, skipped + 1}
          end
        end)
        |> tap(fn {loaded, skipped} ->
          if loaded + skipped > 0 do
            Logger.info(
              "Skills.Bootstrap: seeded #{loaded} new skills, skipped #{skipped} existing"
            )
          end
        end)

      {:error, :enoent} ->
        {0, 0}

      {:error, reason} ->
        Logger.warning("Skills.Bootstrap: cannot read #{skills_dir}: #{inspect(reason)}")
        {0, 0}
    end
  rescue
    e ->
      Logger.warning("Skills.Bootstrap raised: #{Exception.message(e)}")
      {0, 0}
  end

  # -- Private -----------------------------------------------------------------

  defp load_one(path, existing_names) do
    with {:ok, raw} <- File.read(path),
         {:ok, attrs} <- parse_skill_file(raw) do
      if MapSet.member?(existing_names, attrs.name) do
        :skipped
      else
        case Skills.create(attrs) do
          {:ok, _} ->
            :loaded

          {:error, reason} ->
            Logger.warning("Skills.Bootstrap: create failed for #{path}: #{inspect(reason)}")
            :error
        end
      end
    else
      {:error, reason} ->
        Logger.warning("Skills.Bootstrap: parse failed for #{path}: #{inspect(reason)}")
        :error
    end
  end

  # Minimal YAML frontmatter parser: extracts `name:` and `description:`
  # from a `---` ... `---` block at the top of the file, then keeps the
  # whole file (frontmatter included) as the `body`. We don't pull in a
  # full YAML library because the frontmatter shape is fixed and tiny.
  defp parse_skill_file(raw) do
    case String.split(raw, ~r/^---\s*$/m, parts: 3) do
      ["", frontmatter, _rest] ->
        with {:ok, name} <- extract_field(frontmatter, "name"),
             {:ok, description} <- extract_field(frontmatter, "description") do
          {:ok,
           %{
             name: name,
             description: description,
             body: raw,
             scope: :global,
             source: :human
           }}
        end

      _ ->
        {:error, :no_frontmatter}
    end
  end

  defp extract_field(frontmatter, field) do
    # Match: `name: <value>` or `name: "<value>"` on a single line.
    # Description may span lines if not quoted; we accept that here as
    # one logical value by joining continuation lines indented under it.
    pattern = ~r/^#{Regex.escape(field)}:\s*(.+?)(?=\n[a-zA-Z_-]+:|\z)/ms

    case Regex.run(pattern, frontmatter) do
      [_, value] ->
        cleaned =
          value
          |> String.trim()
          |> String.trim_trailing("\n")
          |> String.trim("\"")

        if cleaned == "", do: {:error, {:empty_field, field}}, else: {:ok, cleaned}

      _ ->
        {:error, {:missing_field, field}}
    end
  end

  defp priv_skills_dir do
    case :code.priv_dir(:gitf) do
      {:error, _} ->
        # Fallback for non-release contexts (mix run, escript).
        Path.expand("../../priv/skills", __DIR__)

      dir when is_list(dir) ->
        Path.join(to_string(dir), "skills")
    end
  end
end
