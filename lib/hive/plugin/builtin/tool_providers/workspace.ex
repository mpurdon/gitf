defmodule Hive.Plugin.Builtin.ToolProviders.Workspace do
  @moduledoc """
  Built-in tool provider that exposes workspace/comb/cell info to agents.

  Provides: `list_combs`, `comb_info`, `list_cells`.
  """

  use Hive.Plugin, type: :tool_provider

  @impl true
  def name, do: "workspace"

  @impl true
  def description, do: "Workspace management tools for agents"

  @impl true
  def tools do
    [
      list_combs_tool(),
      comb_info_tool(),
      list_cells_tool()
    ]
  end

  # -- list_combs --------------------------------------------------------------

  defp list_combs_tool do
    ReqLLM.Tool.new!(
      name: "list_combs",
      description: "List all registered combs (repositories/workspaces) with their IDs and paths.",
      callback: fn _args -> list_combs() end
    )
  end

  defp list_combs do
    combs = Hive.Comb.list()

    if combs == [] do
      {:ok, "No combs registered."}
    else
      lines =
        Enum.map(combs, fn c ->
          "#{c.id}: #{c.name} (#{c[:path] || "no path"})"
        end)

      {:ok, Enum.join(lines, "\n")}
    end
  rescue
    e -> {:ok, "Error listing combs: #{Exception.message(e)}"}
  end

  # -- comb_info ---------------------------------------------------------------

  defp comb_info_tool do
    ReqLLM.Tool.new!(
      name: "comb_info",
      description: "Get detailed information about a specific comb by ID or name.",
      parameter_schema: [
        comb_id: [type: :string, required: true, doc: "Comb ID or name"]
      ],
      callback: &comb_info/1
    )
  end

  defp comb_info(args) do
    comb_id = args["comb_id"] || args[:comb_id]

    case Hive.Comb.get(comb_id) do
      {:ok, comb} ->
        info =
          [
            "ID: #{comb.id}",
            "Name: #{comb.name}",
            "Path: #{comb[:path] || "N/A"}",
            "Repo URL: #{comb[:repo_url] || "N/A"}",
            "Merge Strategy: #{comb[:merge_strategy] || "N/A"}",
            "Validation: #{comb[:validation_command] || "N/A"}"
          ]
          |> Enum.join("\n")

        {:ok, info}

      {:error, :not_found} ->
        {:ok, "Comb not found: #{comb_id}"}
    end
  rescue
    e -> {:ok, "Error: #{Exception.message(e)}"}
  end

  # -- list_cells --------------------------------------------------------------

  defp list_cells_tool do
    ReqLLM.Tool.new!(
      name: "list_cells",
      description: "List active cells (worktrees) with their bee assignments.",
      callback: fn _args -> list_cells() end
    )
  end

  defp list_cells do
    cells = Hive.Store.all(:cells)

    if cells == [] do
      {:ok, "No active cells."}
    else
      lines =
        Enum.map(cells, fn c ->
          bee = Map.get(c, :bee_id, "unassigned")
          path = Map.get(c, :path, "unknown")
          "#{c.id}: bee=#{bee} path=#{path}"
        end)

      {:ok, Enum.join(lines, "\n")}
    end
  rescue
    e -> {:ok, "Error listing cells: #{Exception.message(e)}"}
  end
end
