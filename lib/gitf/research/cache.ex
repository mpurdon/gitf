defmodule GiTF.Research.Cache do
  @moduledoc """
  Research caching system to avoid redundant codebase analysis.

  Caches research results per sector with git commit hash tracking.
  Provides file-level granular caching for incremental updates.
  """

  alias GiTF.Archive

  @doc """
  Get cached research for a sector.

  Returns {:ok, research} if valid cache exists, {:error, :not_found} otherwise.
  """
  @spec get_research(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_research(sector_id) do
    case Archive.get(:sector_research_cache, sector_id) do
      nil -> {:error, :not_found}
      cache -> {:ok, cache}
    end
  end

  @doc """
  Check if cached research is still valid for a sector.

  Compares cached git hash with current HEAD commit.
  """
  @spec is_valid?(String.t()) :: boolean()
  def is_valid?(sector_id) do
    with {:ok, cache} <- get_research(sector_id),
         {:ok, sector} <- GiTF.Sector.get(sector_id),
         {:ok, current_hash} <- get_git_hash(sector.path) do
      cache.git_hash == current_hash
    else
      _ -> false
    end
  end

  @doc """
  Archive research results for a sector.

  Saves research with current git hash and file index.
  """
  @spec store_research(String.t(), map(), [map()]) :: {:ok, map()}
  def store_research(sector_id, research, file_index \\ []) do
    with {:ok, sector} <- GiTF.Sector.get(sector_id),
         {:ok, git_hash} <- get_git_hash(sector.path) do
      cache_record = %{
        id: sector_id,
        sector_id: sector_id,
        research: research,
        git_hash: git_hash,
        cached_at: DateTime.utc_now()
      }

      {:ok, cache} = Archive.put(:sector_research_cache, cache_record)

      # Archive file-level research
      Enum.each(file_index, fn file_data ->
        file_record = %{
          sector_id: sector_id,
          file_path: file_data.path,
          research: file_data.research,
          git_hash: git_hash
        }

        Archive.insert(:research_file_index, file_record)
      end)

      {:ok, cache}
    end
  end

  @doc """
  Update research with incremental changes.

  Syncs new research with existing cache.
  """
  @spec update_research(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_research(sector_id, new_research) do
    case get_research(sector_id) do
      {:ok, cache} ->
        updated_research = Map.merge(cache.research, new_research)
        store_research(sector_id, updated_research)

      {:error, :not_found} ->
        store_research(sector_id, new_research)
    end
  end

  @doc """
  Invalidate cached research for a sector.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(sector_id) do
    Archive.delete(:sector_research_cache, sector_id)

    # Delete file-level cache
    Archive.filter(:research_file_index, fn f -> f.sector_id == sector_id end)
    |> Enum.each(fn file -> Archive.delete(:research_file_index, file.id) end)

    :ok
  end

  @doc """
  Get cached research for a specific file.
  """
  @spec get_file_research(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_file_research(sector_id, file_path) do
    case Archive.find_one(:research_file_index, fn f ->
           f.sector_id == sector_id and f.file_path == file_path
         end) do
      nil -> {:error, :not_found}
      file_cache -> {:ok, file_cache}
    end
  end

  # Private helpers

  defp get_git_hash(repo_path) do
    case GiTF.Git.safe_cmd(["rev-parse", "HEAD"], cd: repo_path, stderr_to_stdout: true) do
      {hash, 0} -> {:ok, String.trim(hash)}
      _ -> {:error, :git_failed}
    end
  end
end
