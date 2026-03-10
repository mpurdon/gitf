defmodule Hive.Research.Cache do
  @moduledoc """
  Research caching system to avoid redundant codebase analysis.
  
  Caches research results per comb with git commit hash tracking.
  Provides file-level granular caching for incremental updates.
  """

  alias Hive.Store

  @doc """
  Get cached research for a comb.
  
  Returns {:ok, research} if valid cache exists, {:error, :not_found} otherwise.
  """
  @spec get_research(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_research(comb_id) do
    case Store.get(:comb_research_cache, comb_id) do
      nil -> {:error, :not_found}
      cache -> {:ok, cache}
    end
  end

  @doc """
  Check if cached research is still valid for a comb.
  
  Compares cached git hash with current HEAD commit.
  """
  @spec is_valid?(String.t()) :: boolean()
  def is_valid?(comb_id) do
    with {:ok, cache} <- get_research(comb_id),
         {:ok, comb} <- Hive.Comb.get(comb_id),
         {:ok, current_hash} <- get_git_hash(comb.path) do
      cache.git_hash == current_hash
    else
      _ -> false
    end
  end

  @doc """
  Store research results for a comb.
  
  Saves research with current git hash and file index.
  """
  @spec store_research(String.t(), map(), [map()]) :: {:ok, map()}
  def store_research(comb_id, research, file_index \\ []) do
    with {:ok, comb} <- Hive.Comb.get(comb_id),
         {:ok, git_hash} <- get_git_hash(comb.path) do
      
      cache_record = %{
        id: comb_id,
        comb_id: comb_id,
        research: research,
        git_hash: git_hash,
        cached_at: DateTime.utc_now()
      }

      {:ok, cache} = Store.put(:comb_research_cache, cache_record)
      
      # Store file-level research
      Enum.each(file_index, fn file_data ->
        file_record = %{
          comb_id: comb_id,
          file_path: file_data.path,
          research: file_data.research,
          git_hash: git_hash
        }
        Store.insert(:research_file_index, file_record)
      end)

      {:ok, cache}
    end
  end

  @doc """
  Update research with incremental changes.
  
  Merges new research with existing cache.
  """
  @spec update_research(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_research(comb_id, new_research) do
    case get_research(comb_id) do
      {:ok, cache} ->
        updated_research = Map.merge(cache.research, new_research)
        store_research(comb_id, updated_research)
      
      {:error, :not_found} ->
        store_research(comb_id, new_research)
    end
  end

  @doc """
  Invalidate cached research for a comb.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(comb_id) do
    Store.delete(:comb_research_cache, comb_id)
    
    # Delete file-level cache
    Store.filter(:research_file_index, fn f -> f.comb_id == comb_id end)
    |> Enum.each(fn file -> Store.delete(:research_file_index, file.id) end)
    
    :ok
  end

  @doc """
  Get cached research for a specific file.
  """
  @spec get_file_research(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_file_research(comb_id, file_path) do
    case Store.find_one(:research_file_index, fn f -> 
      f.comb_id == comb_id and f.file_path == file_path 
    end) do
      nil -> {:error, :not_found}
      file_cache -> {:ok, file_cache}
    end
  end

  # Private helpers

  defp get_git_hash(repo_path) do
    case Hive.Git.safe_cmd( ["rev-parse", "HEAD"], cd: repo_path, stderr_to_stdout: true) do
      {hash, 0} -> {:ok, String.trim(hash)}
      _ -> {:error, :git_failed}
    end
  end
end