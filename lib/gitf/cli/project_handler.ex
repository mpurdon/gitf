defmodule GiTF.CLI.ProjectHandler do
  @moduledoc """
  CLI handler for `gitf project` subcommands.

  `project new` runs the interactive planning discussion (`ProjectChat`),
  then creates the project — through the daemon's HTTP API when one is
  running (`GiTF.Client.remote?/0`), otherwise against the local store —
  and optionally approves it so Aramaki starts executing the roadmap.
  """

  alias GiTF.CLI.Format

  def dispatch([:project, :new], _result, _helpers) do
    case GiTF.CLI.ProjectChat.start() do
      {:ok, submission} -> create_and_maybe_approve(submission)
      {:error, :cancelled} -> :ok
      {:error, reason} -> Format.error("Planning failed: #{inspect(reason)}")
    end
  end

  def dispatch([:project, :list], _result, _helpers) do
    projects =
      if GiTF.Client.remote?() do
        case GiTF.Client.list_projects() do
          {:ok, p} -> p
          {:error, reason} -> Format.error("Remote error: #{inspect(reason)}") && []
        end
      else
        GiTF.Project.list()
      end

    case projects do
      [] ->
        Format.info("No projects yet. Create one with `gitf project new`")

      projects ->
        rows =
          Enum.map(projects, fn p ->
            roadmap = p[:roadmap] || []
            done = Enum.count(roadmap, &(item_status(&1) == "completed"))
            [p[:id], p[:name], p[:status], "#{done}/#{length(roadmap)}", p[:sector_id] || "-"]
          end)

        Format.table(["ID", "Name", "Status", "Items", "Sector"], rows)
    end
  end

  def dispatch([:project, :show], result, helpers) do
    id = helpers.result_get.(result, :args, :id)

    project =
      if GiTF.Client.remote?() do
        case GiTF.Client.get_project(id) do
          {:ok, p} -> p
          {:error, _} -> nil
        end
      else
        GiTF.Project.get(id)
      end

    case project do
      nil ->
        Format.error("Project not found: #{id}")

      p ->
        Format.info("#{p[:name]} (#{p[:id]}) — #{p[:status]}")

        if reason = p[:paused_reason], do: Format.warn("Paused: #{reason}")

        vision = get_in(p, [:brief, :vision]) || get_in(p, [:brief, "vision"])
        if vision, do: IO.puts("  #{vision}\n")

        Enum.each(p[:roadmap] || [], fn item ->
          status = item_status(item)

          marker =
            case status do
              "completed" -> "✓"
              "active" -> "▶"
              "failed" -> "✗"
              _ -> "·"
            end

          deps =
            case item[:depends_on] || item["depends_on"] do
              deps when is_list(deps) and deps != [] -> " (after: #{Enum.join(deps, ", ")})"
              _ -> ""
            end

          mission = item[:mission_id] || item["mission_id"]
          mission_note = if mission, do: "  → #{mission}", else: ""

          IO.puts(
            "  #{marker} [#{item[:id] || item["id"]}] #{item[:title] || item["title"]}#{deps}#{mission_note}"
          )
        end)
    end
  end

  def dispatch([:project, :pause], result, helpers) do
    id = helpers.result_get.(result, :args, :id)

    result =
      if GiTF.Client.remote?(),
        do: GiTF.Client.pause_project(id, "operator pause"),
        else: GiTF.Project.pause(id, "operator pause")

    report(result, "Project paused.")
  end

  def dispatch([:project, :resume], result, helpers) do
    id = helpers.result_get.(result, :args, :id)

    result =
      if GiTF.Client.remote?(),
        do: GiTF.Client.resume_project(id),
        else: GiTF.Project.resume(id)

    report(result, "Project resumed.")
  end

  def dispatch(_path, _result, _helpers), do: :not_handled

  # -- project new internals ----------------------------------------------------

  defp create_and_maybe_approve(submission) do
    attrs = %{
      "name" => submission["name"],
      "brief" => submission["brief"],
      "roadmap" => submission["roadmap"],
      "source" => "cli_chat"
    }

    create_result =
      if GiTF.Client.remote?(),
        do: GiTF.Client.create_project(attrs),
        else: GiTF.Project.create(attrs)

    case create_result do
      {:ok, project} ->
        Format.success("Project created: #{project[:name]} (#{project[:id]})")
        maybe_approve(project, submission["sector"])

      {:error, reason} ->
        Format.error("Failed to create project: #{inspect(reason)}")
    end
  end

  defp maybe_approve(project, sector) do
    answer =
      IO.gets("  Approve and start now? [y/n] ")
      |> to_string()
      |> String.trim()
      |> String.downcase()

    if answer in ["y", "yes", ""] do
      case approve(project[:id], sector) do
        {:ok, _} ->
          Format.success("Project approved — Aramaki will run the roadmap.")

          unless GiTF.Client.remote?() do
            Format.warn("No daemon detected: missions start when `gitf server` is running.")
          end

        {:error, reason} ->
          Format.error("Approval failed: #{inspect(reason)}")
          Format.info("The project is saved as a draft. Approve later via the API or dashboard.")
      end
    else
      Format.info("Saved as draft #{project[:id]}. Approve later via the API or dashboard.")
    end
  end

  defp approve(id, %{"mode" => "new", "name" => name}) do
    if GiTF.Client.remote?() do
      GiTF.Client.approve_project(id, %{create_sector: name})
    else
      with {:ok, sector} <- GiTF.Sector.create_new(name),
           {:ok, _} <- GiTF.Project.assign_sector(id, sector.id) do
        GiTF.Project.activate(id)
      end
    end
  end

  defp approve(id, %{"mode" => "existing", "name" => name}) do
    if GiTF.Client.remote?() do
      GiTF.Client.approve_project(id, %{sector_id: name})
    else
      with {:ok, sector} <- GiTF.Sector.get(name),
           {:ok, _} <- GiTF.Project.assign_sector(id, sector.id) do
        GiTF.Project.activate(id)
      end
    end
  end

  defp approve(id, _), do: approve(id, %{"mode" => "new", "name" => "project-#{id}"})

  defp report({:ok, _}, message), do: Format.success(message)
  defp report({:error, reason}, _), do: Format.error(inspect(reason))

  defp item_status(item), do: item[:status] || item["status"]
end
