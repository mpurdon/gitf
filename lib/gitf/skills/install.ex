defmodule GiTF.Skills.Install do
  @moduledoc """
  Writes retrieved skills into a ghost's worktree so Claude Code can
  discover them at runtime.

  Mirrors the `GiTF.AgentProfile.install_agents/2` pattern: the source of
  truth is the Archive (`:skills` collection), and each install copies
  content into the worktree's `.claude/skills/` directory.

  Installation is idempotent: re-running with the same skill list is a
  no-op (content hash match) — safe for ghost restart paths.
  """

  require Logger

  alias GiTF.Skills

  @skills_dir ".claude/skills"

  @doc """
  Installs the given skills into the worktree. Returns the list of
  installed skill IDs so callers can track what the op saw.

  Best-effort: filesystem errors are logged but do not crash. An
  install failure should never block ghost provisioning — the ghost
  can still run without skills.
  """
  @spec install_into_worktree([Skills.t()], String.t()) :: [String.t()]
  def install_into_worktree([], _worktree_path), do: []

  def install_into_worktree(skills, worktree_path) when is_list(skills) do
    dst_dir = Path.join(worktree_path, @skills_dir)

    case File.mkdir_p(dst_dir) do
      :ok ->
        skills
        |> Enum.flat_map(fn skill -> install_one(skill, dst_dir) end)
        |> tap(&maybe_emit_telemetry(&1, worktree_path))

      {:error, reason} ->
        Logger.warning(
          "Skills.Install: failed to create #{dst_dir}: #{inspect(reason)}"
        )

        []
    end
  rescue
    e ->
      Logger.warning("Skills.Install raised: #{Exception.message(e)}")
      []
  end

  # -- Private -----------------------------------------------------------------

  defp install_one(%{id: id, body: body} = skill, dst_dir)
       when is_binary(id) and is_binary(body) do
    file_path = Path.join(dst_dir, "#{id}.md")

    case write_if_changed(file_path, body) do
      :written ->
        Skills.bump_applied(id)
        [id]

      :unchanged ->
        [id]

      {:error, reason} ->
        Logger.warning(
          "Skills.Install: failed to write #{file_path}: #{inspect(reason)}; skill=#{id} (#{skill.name})"
        )

        []
    end
  end

  defp install_one(_bad_skill, _dst_dir), do: []

  # Writes the body only if the file is absent or its contents differ.
  # Protects against redundant applied_count increments on ghost restarts.
  defp write_if_changed(path, body) do
    case File.read(path) do
      {:ok, ^body} ->
        :unchanged

      {:ok, _stale} ->
        case File.write(path, body) do
          :ok -> :written
          err -> err
        end

      {:error, :enoent} ->
        case File.write(path, body) do
          :ok -> :written
          err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  defp maybe_emit_telemetry([], _worktree_path), do: :ok

  defp maybe_emit_telemetry(ids, worktree_path) do
    GiTF.Telemetry.emit(
      [:gitf, :skills, :installed],
      %{count: length(ids)},
      %{worktree: worktree_path, skill_ids: ids}
    )
  rescue
    e ->
      Logger.debug("Skills.Install telemetry emit failed: #{Exception.message(e)}")
      :ok
  end
end
