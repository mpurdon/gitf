defmodule Hive.Comb do
  @moduledoc """
  Context module for managing combs -- the git repositories tracked by a hive.

  A comb can be either a local directory that already exists on disk or a
  remote URL that gets cloned. This module handles registration, lookup,
  and removal of comb records in the store.

  This is a pure context module with no process state. Every function
  transforms input data into a store operation and returns the result.
  """

  alias Hive.Store

  @doc """
  Registers a comb with the hive.

  For a local path, validates that the directory exists. For a remote URL,
  clones the repository into the hive workspace.

  ## Options

    * `:name` - a human-friendly name. Defaults to the basename of the path or repo URL.

  Returns `{:ok, comb}` or `{:error, reason}`.
  """
  @spec add(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def add(path_or_url, opts \\ []) do
    if Hive.Git.local_path?(path_or_url) do
      add_local(path_or_url, opts)
    else
      add_remote(path_or_url, opts)
    end
  end

  @doc """
  Returns all registered combs.
  """
  @spec list() :: [map()]
  def list do
    Store.all(:combs)
  end

  @doc """
  Finds a comb by name or ID.

  Returns `{:ok, comb}` or `{:error, :not_found}`.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(name_or_id) do
    case Store.get(:combs, name_or_id) do
      nil ->
        case Store.find_one(:combs, fn c -> c.name == name_or_id end) do
          nil -> {:error, :not_found}
          comb -> {:ok, comb}
        end

      comb ->
        {:ok, comb}
    end
  end

  @doc """
  Removes a comb record from the store.

  ## Options

    * `:delete_files` - when `true`, also removes the comb directory from disk.
      Defaults to `false`.

  Returns `{:ok, comb}` or `{:error, :not_found}`.
  """
  @spec remove(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def remove(name_or_id, opts \\ []) do
    with {:ok, comb} <- get(name_or_id) do
      if Keyword.get(opts, :delete_files, false) && comb[:path] do
        File.rm_rf(comb.path)
      end

      Store.delete(:combs, comb.id)
      {:ok, comb}
    end
  end

  @doc """
  Returns the current comb from the session config.

  Returns `{:ok, comb}` or `{:error, :no_current_comb}`.
  """
  @spec current() :: {:ok, map()} | {:error, :no_current_comb}
  def current do
    with {:ok, hive_root} <- Hive.hive_dir(),
         config_path = Path.join([hive_root, ".hive", "config.toml"]),
         {:ok, config} <- Hive.Config.read_config(config_path),
         id when is_binary(id) and id != "" <- get_in(config, ["session", "current_comb"]),
         {:ok, comb} <- get(id) do
      {:ok, comb}
    else
      _ -> {:error, :no_current_comb}
    end
  end

  @doc """
  Sets the current comb in the session config.

  Accepts a comb name or ID. Returns `{:ok, comb}` or `{:error, reason}`.
  """
  @spec set_current(String.t()) :: {:ok, map()} | {:error, term()}
  def set_current(name_or_id) do
    with {:ok, comb} <- get(name_or_id),
         {:ok, hive_root} <- Hive.hive_dir(),
         config_path = Path.join([hive_root, ".hive", "config.toml"]),
         {:ok, config} <- Hive.Config.read_config(config_path) do
      updated =
        Map.update(config, "session", %{"current_comb" => comb.id}, fn session ->
          Map.put(session, "current_comb", comb.id)
        end)

      case Hive.Config.write_config(config_path, updated) do
        :ok -> {:ok, comb}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Renames a comb and updates all stored path references.

  If the comb directory exists on disk and its basename matches the old name,
  the directory is also renamed and all cell/bee paths are updated.

  Returns `{:ok, updated_comb}` or `{:error, reason}`.
  """
  @spec rename(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def rename(name_or_id, new_name) do
    with {:ok, comb} <- get(name_or_id),
         :ok <- validate_name_available(new_name, comb.id) do
      old_name = comb.name
      updated = %{comb | name: new_name}

      if comb.path && File.dir?(comb.path) && Path.basename(comb.path) == old_name do
        new_path = Path.join(Path.dirname(comb.path), new_name)

        case File.rename(comb.path, new_path) do
          :ok ->
            updated = %{updated | path: new_path}
            Store.put(:combs, updated)
            update_stored_paths(comb.path, new_path)
            {:ok, updated}

          {:error, reason} ->
            {:error, {:rename_failed, reason}}
        end
      else
        Store.put(:combs, updated)
        {:ok, updated}
      end
    end
  end

  # -- Private helpers -------------------------------------------------------

  defp add_local(path, opts) do
    expanded = Path.expand(path)

    with :ok <- validate_directory(expanded),
         :ok <- validate_unique_name(opts, expanded) do
      name = Keyword.get(opts, :name, Path.basename(expanded))

      record = %{
        name: name,
        path: expanded,
        repo_url: nil,
        merge_strategy: Keyword.get(opts, :merge_strategy, "manual"),
        validation_command: Keyword.get(opts, :validation_command),
        github_owner: Keyword.get(opts, :github_owner),
        github_repo: Keyword.get(opts, :github_repo)
      }

      with {:ok, comb} <- Store.insert(:combs, record) do
        set_current(comb.id)
        {:ok, comb}
      end
    end
  end

  defp add_remote(url, opts) do
    name = Keyword.get(opts, :name, repo_name_from_url(url))

    with {:ok, hive_root} <- Hive.hive_dir(),
         destination = Path.join([hive_root, ".hive", "combs", name]),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         {:ok, cloned_path} <- Hive.Git.clone(url, destination) do
      record = %{
        name: name,
        repo_url: url,
        path: cloned_path,
        merge_strategy: Keyword.get(opts, :merge_strategy, "manual"),
        validation_command: Keyword.get(opts, :validation_command),
        github_owner: Keyword.get(opts, :github_owner),
        github_repo: Keyword.get(opts, :github_repo)
      }

      with {:ok, comb} <- Store.insert(:combs, record) do
        set_current(comb.id)
        {:ok, comb}
      end
    end
  end

  defp validate_directory(path) do
    if File.dir?(path), do: :ok, else: {:error, :path_not_found}
  end

  defp validate_unique_name(opts, expanded) do
    name = Keyword.get(opts, :name, Path.basename(expanded))

    case Store.find_one(:combs, fn c -> c.name == name end) do
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
    case Store.find_one(:combs, fn c -> c.name == name && c.id != excluding_id end) do
      nil -> :ok
      _existing -> {:error, :name_already_taken}
    end
  end

  defp update_stored_paths(old_path, new_path) do
    Store.filter(:cells, fn c ->
      is_binary(c[:worktree_path]) && String.starts_with?(c.worktree_path, old_path)
    end)
    |> Enum.each(fn cell ->
      updated_path = String.replace_prefix(cell.worktree_path, old_path, new_path)
      Store.put(:cells, %{cell | worktree_path: updated_path})
    end)

    Store.filter(:bees, fn b ->
      is_binary(b[:cell_path]) && String.starts_with?(b.cell_path, old_path)
    end)
    |> Enum.each(fn bee ->
      updated_path = String.replace_prefix(bee.cell_path, old_path, new_path)
      Store.put(:bees, %{bee | cell_path: updated_path})
    end)
  end
end
