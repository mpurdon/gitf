defmodule GiTF.Sector do
  @moduledoc """
  Context module for managing sectors -- the git repositories tracked by the section.

  A sector can be either a local directory that already exists on disk or a
  remote URL that gets cloned. This module handles registration, lookup,
  and removal of sector records in the store.

  This is a pure context module with no process state. Every function
  transforms input data into a store operation and returns the result.
  """

  alias GiTF.Archive
  require Logger

  @doc """
  Registers a sector with the section.

  For a local path, validates that the directory exists. For a remote URL,
  clones the repository into the gitf workspace.

  ## Options

    * `:name` - a human-friendly name. Defaults to the basename of the path or repo URL.

  Returns `{:ok, sector}` or `{:error, reason}`.
  """
  @spec add(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def add(path_or_url, opts \\ []) do
    if GiTF.Git.local_path?(path_or_url) do
      add_local(path_or_url, opts)
    else
      add_remote(path_or_url, opts)
    end
  end

  @doc """
  Returns all registered sectors.
  """
  @spec list() :: [map()]
  def list do
    Archive.all(:sectors)
  end

  @doc """
  Finds a sector by name or ID.

  Returns `{:ok, sector}` or `{:error, :not_found}`.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(name_or_id) do
    case Archive.get(:sectors, name_or_id) do
      nil ->
        case Archive.find_one(:sectors, fn c -> c.name == name_or_id end) do
          nil -> {:error, :not_found}
          sector -> {:ok, sector}
        end

      sector ->
        {:ok, sector}
    end
  end

  @doc """
  Removes a sector record from the store.

  ## Options

    * `:delete_files` - when `true`, also removes the sector directory from disk.
      Defaults to `false`.

  Returns `{:ok, sector}` or `{:error, :not_found}`.
  """
  @spec remove(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def remove(name_or_id, opts \\ []) do
    with {:ok, sector} <- get(name_or_id) do
      if Keyword.get(opts, :delete_files, false) && sector[:path] do
        File.rm_rf(sector.path)
      end

      Archive.delete(:sectors, sector.id)
      {:ok, sector}
    end
  end

  @doc """
  Returns the current sector from the session config.

  Returns `{:ok, sector}` or `{:error, :no_current_sector}`.
  """
  @spec current() :: {:ok, map()} | {:error, :no_current_sector}
  def current do
    with {:ok, gitf_root} <- GiTF.gitf_dir(),
         config_path = Path.join([gitf_root, ".gitf", "config.toml"]),
         {:ok, config} <- GiTF.Config.read_config(config_path),
         id when is_binary(id) and id != "" <- get_in(config, ["session", "current_sector"]),
         {:ok, sector} <- get(id) do
      {:ok, sector}
    else
      _ -> {:error, :no_current_sector}
    end
  end

  @doc """
  Sets the current sector in the session config.

  Accepts a sector name or ID. Returns `{:ok, sector}` or `{:error, reason}`.
  """
  @spec set_current(String.t()) :: {:ok, map()} | {:error, term()}
  def set_current(name_or_id) do
    with {:ok, sector} <- get(name_or_id),
         {:ok, gitf_root} <- GiTF.gitf_dir(),
         config_path = Path.join([gitf_root, ".gitf", "config.toml"]),
         {:ok, config} <- GiTF.Config.read_config(config_path) do
      updated =
        Map.update(config, "session", %{"current_sector" => sector.id}, fn session ->
          Map.put(session, "current_sector", sector.id)
        end)

      case GiTF.Config.write_config(config_path, updated) do
        :ok -> {:ok, sector}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Backfills `github_owner` and `github_repo` on sectors that have a local path
  with a GitHub remote but no GitHub config set. Safe to call on boot.
  """
  @spec backfill_github_config() :: :ok
  def backfill_github_config do
    list()
    |> Enum.each(fn sector ->
      if sector.path && is_nil(Map.get(sector, :github_owner)) do
        {owner, repo} = detect_github_remote(sector.path)

        if owner && repo do
          updated =
            sector
            |> Map.put(:github_owner, owner)
            |> Map.put(:github_repo, repo)

          Archive.put(:sectors, updated)
          Logger.info("Sector #{sector.name}: detected GitHub #{owner}/#{repo}")
        end
      end
    end)
  end

  @doc """
  Renames a sector and updates all stored path references.

  If the sector directory exists on disk and its basename matches the old name,
  the directory is also renamed and all shell/ghost paths are updated.

  Returns `{:ok, updated_comb}` or `{:error, reason}`.
  """
  @spec rename(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def rename(name_or_id, new_name) do
    with {:ok, sector} <- get(name_or_id),
         :ok <- validate_name_available(new_name, sector.id) do
      old_name = sector.name
      updated = %{sector | name: new_name}

      if sector.path && File.dir?(sector.path) && Path.basename(sector.path) == old_name do
        new_path = Path.join(Path.dirname(sector.path), new_name)

        case File.rename(sector.path, new_path) do
          :ok ->
            updated = %{updated | path: new_path}
            Archive.put(:sectors, updated)
            update_stored_paths(sector.path, new_path)
            {:ok, updated}

          {:error, reason} ->
            {:error, {:rename_failed, reason}}
        end
      else
        Archive.put(:sectors, updated)
        {:ok, updated}
      end
    end
  end

  # -- Private helpers -------------------------------------------------------

  defp add_local(path, opts) do
    expanded = Path.expand(path)

    with :ok <- validate_directory(expanded),
         :ok <- validate_git_repo(expanded),
         :ok <- validate_unique_name(opts, expanded) do
      name = Keyword.get(opts, :name, Path.basename(expanded))

      # Auto-detect GitHub owner/repo from git remote if not explicitly provided
      {gh_owner, gh_repo} =
        case {Keyword.get(opts, :github_owner), Keyword.get(opts, :github_repo)} do
          {o, r} when is_binary(o) and is_binary(r) -> {o, r}
          _ -> detect_github_remote(expanded)
        end

      record = %{
        name: name,
        path: expanded,
        repo_url: nil,
        sync_strategy: Keyword.get(opts, :sync_strategy, "manual"),
        validation_command: Keyword.get(opts, :validation_command),
        github_owner: gh_owner,
        github_repo: gh_repo
      }

      with {:ok, sector} <- Archive.insert(:sectors, record) do
        set_current(sector.id)
        {:ok, sector}
      end
    end
  end

  defp add_remote(url, opts) do
    name = Keyword.get(opts, :name, repo_name_from_url(url))

    with {:ok, gitf_root} <- GiTF.gitf_dir(),
         destination = Path.join([gitf_root, ".gitf", "sectors", name]),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         {:ok, cloned_path} <- GiTF.Git.clone(url, destination) do
      record = %{
        name: name,
        repo_url: url,
        path: cloned_path,
        sync_strategy: Keyword.get(opts, :sync_strategy, "manual"),
        validation_command: Keyword.get(opts, :validation_command),
        github_owner: Keyword.get(opts, :github_owner),
        github_repo: Keyword.get(opts, :github_repo)
      }

      with {:ok, sector} <- Archive.insert(:sectors, record) do
        set_current(sector.id)
        {:ok, sector}
      end
    end
  end

  defp validate_directory(path) do
    if File.dir?(path), do: :ok, else: {:error, :path_not_found}
  end

  defp validate_git_repo(path) do
    if not File.dir?(Path.join(path, ".git")) do
      {:error, {:invalid_repo, "Not a git repository (no .git directory)"}}
    else
      case System.cmd("git", ["rev-parse", "HEAD"], cd: path, stderr_to_stdout: true) do
        {_, 0} ->
          :ok

        {_, _} ->
          {:error,
           {:invalid_repo,
            "Git repo has no commits. Run: git add -A && git commit -m \"Initial commit\""}}
      end
    end
  end

  defp validate_unique_name(opts, expanded) do
    name = Keyword.get(opts, :name, Path.basename(expanded))

    case Archive.find_one(:sectors, fn c -> c.name == name end) do
      nil -> :ok
      _existing -> {:error, :name_already_taken}
    end
  end

  defp repo_name_from_url(url) do
    url
    |> String.split("/")
    |> List.last()
    |> String.replace(~r/\.git$/, "")
  end

  defp validate_name_available(name, excluding_id) do
    case Archive.find_one(:sectors, fn c -> c.name == name && c.id != excluding_id end) do
      nil -> :ok
      _existing -> {:error, :name_already_taken}
    end
  end

  defp update_stored_paths(old_path, new_path) do
    Archive.filter(:shells, fn c ->
      is_binary(c[:worktree_path]) && String.starts_with?(c.worktree_path, old_path)
    end)
    |> Enum.each(fn shell ->
      updated_path = String.replace_prefix(shell.worktree_path, old_path, new_path)
      Archive.put(:shells, %{shell | worktree_path: updated_path})
    end)

    Archive.filter(:ghosts, fn b ->
      is_binary(b[:shell_path]) && String.starts_with?(b.shell_path, old_path)
    end)
    |> Enum.each(fn ghost ->
      updated_path = String.replace_prefix(ghost.shell_path, old_path, new_path)
      Archive.put(:ghosts, %{ghost | shell_path: updated_path})
    end)
  end

  defp detect_github_remote(repo_path) do
    case GiTF.Git.safe_cmd(["remote", "get-url", "origin"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {url, 0} ->
        url = String.trim(url)
        parse_github_url(url)

      _ ->
        {nil, nil}
    end
  rescue
    _ -> {nil, nil}
  end

  # Parse owner/repo from GitHub URLs:
  #   https://github.com/owner/repo.git
  #   git@github.com:owner/repo.git
  defp parse_github_url(url) do
    case Regex.run(~r{github\.com[:/]([^/]+)/([^/.]+)}, url) do
      [_, owner, repo] -> {owner, repo}
      _ -> {nil, nil}
    end
  end
end
