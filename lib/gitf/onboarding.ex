defmodule GiTF.Onboarding do
  @moduledoc """
  Automated onboarding for brownfield projects.
  Detects project type, generates codebase map, and configures the sector.
  """

  alias GiTF.Onboarding.{Detector, Mapper}
  alias GiTF.Sector

  @doc """
  Onboard a project with automatic detection and configuration.
  
  Options:
  - :name - Comb name (defaults to directory name)
  - :skip_research - Skip initial research cache generation
  - :validation_command - Override detected validation command
  """
  def onboard(path, opts \\ []) do
    with {:ok, full_path} <- validate_path(path),
         {:ok, project_info} <- detect_project(full_path),
         {:ok, codebase_map} <- map_codebase(full_path, project_info),
         {:ok, sector} <- create_comb(full_path, project_info, codebase_map, opts),
         {:ok, _} <- maybe_generate_research(sector, opts) do
      {:ok, %{sector: sector, project_info: project_info, codebase_map: codebase_map}}
    end
  end

  @doc """
  Quick onboard - minimal configuration, fast setup.
  """
  def quick_onboard(path, opts \\ []) do
    opts = Keyword.put(opts, :skip_research, true)
    onboard(path, opts)
  end

  defp validate_path(path) do
    full_path = Path.expand(path)
    
    cond do
      not File.exists?(full_path) ->
        {:error, "Path does not exist: #{path}"}
      
      not File.dir?(full_path) ->
        {:error, "Path is not a directory: #{path}"}
      
      not is_git_repo?(full_path) ->
        {:error, "Path is not a git repository: #{path}"}
      
      true ->
        {:ok, full_path}
    end
  end

  defp is_git_repo?(path) do
    File.dir?(Path.join(path, ".git"))
  end

  defp detect_project(path) do
    project_info = Detector.detect(path)
    
    if project_info.language == :unknown do
      {:error, "Could not detect project language"}
    else
      {:ok, project_info}
    end
  end

  defp map_codebase(path, project_info) do
    codebase_map = Mapper.map(path, project_info)
    {:ok, codebase_map}
  end

  defp create_comb(path, project_info, _codebase_map, opts) do
    name = opts[:name] || Path.basename(path)
    validation_cmd = opts[:validation_command] || project_info.validation_command
    
    comb_opts = [
      name: name,
      validation_command: validation_cmd,
      sync_strategy: suggest_sync_strategy(project_info)
    ]
    
    case Comb.add(path, comb_opts) do
      {:ok, sector} -> {:ok, sector}
      {:error, reason} -> {:error, "Failed to create sector: #{inspect(reason)}"}
    end
  end

  defp suggest_sync_strategy(%{project_type: :library}), do: :pr_branch
  defp suggest_sync_strategy(%{test_framework: nil}), do: :manual
  defp suggest_sync_strategy(_), do: :auto_merge

  defp maybe_generate_research(_comb, _opts) do
    {:ok, :skipped}
  end

  @doc """
  Get onboarding suggestions for a path without creating a sector.
  """
  def preview(path) do
    with {:ok, full_path} <- validate_path(path),
         {:ok, project_info} <- detect_project(full_path),
         {:ok, codebase_map} <- map_codebase(full_path, project_info) do
      {:ok, %{
        project_info: project_info,
        codebase_map: codebase_map,
        suggestions: %{
          name: Path.basename(full_path),
          validation_command: project_info.validation_command,
          sync_strategy: suggest_sync_strategy(project_info)
        }
      }}
    end
  end
end
