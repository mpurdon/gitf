defmodule GiTF.Plugin.Builtin.ToolProviders.Workspace do
  @moduledoc """
  Built-in tool provider that exposes workspace/sector/shell info to agents.

  Provides: `list_sectors`, `sector_info`, `list_cells`.
  """

  use GiTF.Plugin, type: :tool_provider

  @impl true
  def name, do: "workspace"

  @impl true
  def description, do: "Workspace management tools for agents"

  @impl true
  def tools do
    [
      list_sectors_tool(),
      sector_info_tool(),
      list_cells_tool()
    ]
  end

  # -- list_sectors --------------------------------------------------------------

  defp list_sectors_tool do
    ReqLLM.Tool.new!(
      name: "list_sectors",
      description:
        "List all registered sectors (repositories/workspaces) with their IDs and paths.",
      callback: fn _args -> list_sectors() end
    )
  end

  defp list_sectors do
    sectors = GiTF.Sector.list()

    if sectors == [] do
      {:ok, "No sectors registered."}
    else
      lines =
        Enum.map(sectors, fn c ->
          "#{c.id}: #{c.name} (#{c[:path] || "no path"})"
        end)

      {:ok, Enum.join(lines, "\n")}
    end
  rescue
    e -> {:ok, "Error listing sectors: #{Exception.message(e)}"}
  end

  # -- sector_info ---------------------------------------------------------------

  defp sector_info_tool do
    ReqLLM.Tool.new!(
      name: "sector_info",
      description: "Get detailed information about a specific sector by ID or name.",
      parameter_schema: [
        sector_id: [type: :string, required: true, doc: "Sector ID or name"]
      ],
      callback: &sector_info/1
    )
  end

  defp sector_info(args) do
    sector_id = args["sector_id"] || args[:sector_id]

    case GiTF.Sector.get(sector_id) do
      {:ok, sector} ->
        info =
          [
            "ID: #{sector.id}",
            "Name: #{sector.name}",
            "Path: #{sector[:path] || "N/A"}",
            "Repo URL: #{sector[:repo_url] || "N/A"}",
            "Sync Strategy: #{sector[:sync_strategy] || "N/A"}",
            "Validation: #{sector[:validation_command] || "N/A"}"
          ]
          |> Enum.join("\n")

        {:ok, info}

      {:error, :not_found} ->
        {:ok, "Sector not found: #{sector_id}"}
    end
  rescue
    e -> {:ok, "Error: #{Exception.message(e)}"}
  end

  # -- list_cells --------------------------------------------------------------

  defp list_cells_tool do
    ReqLLM.Tool.new!(
      name: "list_cells",
      description: "List active shells (worktrees) with their ghost assignments.",
      callback: fn _args -> list_cells() end
    )
  end

  defp list_cells do
    shells = GiTF.Archive.all(:shells)

    if shells == [] do
      {:ok, "No active shells."}
    else
      lines =
        Enum.map(shells, fn c ->
          ghost = Map.get(c, :ghost_id, "unassigned")
          path = Map.get(c, :path, "unknown")
          "#{c.id}: ghost=#{ghost} path=#{path}"
        end)

      {:ok, Enum.join(lines, "\n")}
    end
  rescue
    e -> {:ok, "Error listing shells: #{Exception.message(e)}"}
  end
end
