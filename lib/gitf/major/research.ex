defmodule GiTF.Major.Research do
  @moduledoc """
  Major's codebase research capabilities.
  
  Analyzes sector structure, patterns, and architecture to inform planning.
  Uses caching to avoid redundant analysis of unchanged codebases.
  """

  alias GiTF.Research.Cache

  @doc """
  Research a sector's codebase structure and patterns.
  
  Returns cached results if available and valid, otherwise performs fresh analysis.
  """
  @spec research_comb(String.t()) :: {:ok, map()} | {:error, term()}
  def research_comb(sector_id) do
    if Cache.is_valid?(sector_id) do
      Cache.get_research(sector_id)
    else
      perform_fresh_research(sector_id)
    end
  end

  @doc """
  Perform fresh codebase analysis.
  
  Basic structure analysis - will be enhanced with model-based analysis later.
  """
  @spec perform_fresh_research(String.t()) :: {:ok, map()} | {:error, term()}
  def perform_fresh_research(sector_id) do
    with {:ok, sector} <- GiTF.Sector.get(sector_id),
         {:ok, structure} <- analyze_structure(sector.path) do
      
      research = %{
        structure: structure,
        analyzed_at: DateTime.utc_now(),
        analysis_type: "basic_structure"
      }
      
      Cache.store_research(sector_id, research)
    end
  end

  @doc """
  Analyze basic codebase structure.
  
  Returns directory tree, file types, and basic patterns.
  """
  @spec analyze_structure(String.t()) :: {:ok, map()} | {:error, term()}
  def analyze_structure(sector_path) do
    with {:ok, files} <- list_source_files(sector_path) do
      structure = %{
        total_files: length(files),
        file_types: group_by_extension(files),
        directories: extract_directories(files),
        main_language: detect_main_language(files)
      }
      
      {:ok, structure}
    end
  end

  # Private helpers (made public for testing)

  def group_by_extension(files) do
    files
    |> Enum.group_by(&Path.extname/1)
    |> Map.new(fn {ext, file_list} -> {ext, length(file_list)} end)
  end

  def detect_main_language(files) do
    extensions = group_by_extension(files)
    
    language_map = %{
      ".ex" => "elixir",
      ".exs" => "elixir", 
      ".js" => "javascript",
      ".ts" => "typescript",
      ".py" => "python",
      ".rs" => "rust",
      ".go" => "go",
      ".rb" => "ruby"
    }
    
    extensions
    |> Enum.map(fn {ext, count} -> {Map.get(language_map, ext, "other"), count} end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {lang, counts} -> {lang, Enum.sum(counts)} end)
    |> Enum.max_by(&elem(&1, 1), fn -> {"unknown", 0} end)
    |> elem(0)
  end

  # Private helpers

  defp list_source_files(path) do
    task = Task.async(fn ->
      System.cmd("find", [path, "-type", "f", "-not", "-path", "*/.*"], stderr_to_stdout: true)
    end)

    case Task.yield(task, 30_000) || Task.exfil(task, 5_000) do
      {:ok, {output, 0}} ->
        files =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.replace_prefix(&1, path <> "/", ""))
          |> Enum.reject(&String.starts_with?(&1, "."))

        {:ok, files}

      {:ok, _} -> {:error, :find_failed}
      nil -> {:error, :find_timeout}
    end
  end

  defp extract_directories(files) do
    files
    |> Enum.map(&Path.dirname/1)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == "."))
    |> Enum.sort()
  end
end