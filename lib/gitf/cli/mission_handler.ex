defmodule GiTF.CLI.MissionHandler do
  @moduledoc """
  CLI handler for mission subcommands.

  Extracted from `GiTF.CLI` to reduce the monolithic dispatch file.
  The main CLI module delegates mission-related dispatch calls here.
  """

  alias GiTF.CLI.Format

  def dispatch([:mission, :new], result, helpers) do
    goal = helpers.result_get.(result, :args, :goal)

    if GiTF.Client.remote?() do
      sector_opt = helpers.result_get.(result, :options, :sector)
      attrs = if sector_opt, do: %{goal: goal, sector_id: sector_opt}, else: %{goal: goal}

      case GiTF.Client.create_quest(attrs) do
        {:ok, mission} ->
          Format.success("Quest created: #{mission.name} (#{mission.id})")
          Format.info("Starting mission execution on remote server...")

          case GiTF.Client.start_quest(mission.id) do
            {:ok, data} ->
              phase = if is_map(data), do: data[:phase], else: data
              Format.success("Quest #{mission.id} is now in #{phase} phase.")

            {:error, reason} ->
              Format.warn("Could not auto-start: #{inspect(reason)}")
          end

        {:error, reason} ->
          Format.error("Failed to create mission: #{inspect(reason)}")
      end
    else
      goal =
        if goal == nil or goal == "" do
          answer = IO.gets("What do you want to build? ") |> String.trim()
          if answer == "", do: System.halt(0), else: answer
        else
          goal
        end

      quest_result =
        case helpers.resolve_sector_id.(helpers.result_get.(result, :options, :sector)) do
          {:ok, cid} -> GiTF.Missions.create(%{goal: goal, sector_id: cid})
          {:error, :no_sector} -> GiTF.Missions.create(%{goal: goal})
        end

      case quest_result do
        {:ok, mission} ->
          Format.success("Quest created: #{mission.name} (#{mission.id})")
          GiTF.CLI.PlanHandler.start_interactive_planning(mission)

        {:error, reason} ->
          Format.error("Failed to create mission: #{inspect(reason)}")
      end
    end
  end

  def dispatch([:mission, :list], _result, _helpers) do
    missions =
      if GiTF.Client.remote?() do
        case GiTF.Client.list_quests() do
          {:ok, q} ->
            q

          {:error, reason} ->
            Format.error("Remote error: #{inspect(reason)}")
            []
        end
      else
        GiTF.Missions.list()
      end

    case missions do
      [] ->
        Format.info("No missions yet. Create one with `gitf mission new \"<goal>\"`")

      missions ->
        headers = ["ID", "Name", "Phase", "Status", "Jobs", "Created"]

        rows =
          Enum.map(missions, fn q ->
            job_summary =
              case q[:ops] do
                nil -> "-"
                ops -> "#{length(ops)}"
              end

            created =
              case q[:inserted_at] do
                nil -> "-"
                ts when is_binary(ts) -> String.slice(ts, 0, 10)
                ts -> Calendar.strftime(ts, "%Y-%m-%d")
              end

            phase = q[:current_phase] || "-"
            [q.id, q.name, phase, q.status, job_summary, created]
          end)

        Format.table(headers, rows)
    end
  end

  def dispatch([:mission, :show], result, helpers) do
    id = helpers.result_get.(result, :args, :id)

    quest_result =
      if GiTF.Client.remote?(),
        do: GiTF.Client.get_quest(id),
        else: GiTF.Missions.get(id)

    case quest_result do
      {:ok, mission} ->
        IO.puts("Quest: #{mission.name}")
        IO.puts("ID:     #{mission.id}")
        IO.puts("Status: #{mission.status}")
        IO.puts("Phase:  #{mission[:current_phase] || "pending"}")
        IO.puts("")

        unless GiTF.Client.remote?() do
          # Phase timeline
          display_phase_timeline(mission)

          # Artifact summaries
          display_artifact_summaries(mission)
        end

        # Jobs table
        case mission[:ops] do
          nil ->
            Format.info("No ops yet.")

          [] ->
            Format.info("No ops yet.")

          ops ->
            # Separate phase ops from implementation ops
            phase_jobs = Enum.filter(ops, & &1[:phase_job])
            impl_jobs = Enum.reject(ops, & &1[:phase_job])

            if impl_jobs != [] do
              IO.puts("Implementation Jobs:")
              headers = ["Job ID", "Title", "Status", "Ghost", "Model"]

              rows =
                Enum.map(impl_jobs, fn j ->
                  [
                    j.id,
                    String.slice(to_string(j.title), 0, 50),
                    j.status,
                    j[:ghost_id] || "-",
                    j[:assigned_model] || "-"
                  ]
                end)

              Format.table(headers, rows)
            end

            if phase_jobs != [] do
              IO.puts("\nPhase Jobs:")
              headers = ["Phase", "Status", "Job ID"]

              rows =
                Enum.map(phase_jobs, fn j ->
                  [j[:phase] || "-", j.status, j.id]
                end)

              Format.table(headers, rows)
            end
        end

      {:error, :not_found} ->
        Format.error("Quest not found: #{id}")
    end
  end

  def dispatch([:mission, :remove], result, helpers) do
    id = helpers.result_get.(result, :args, :id)

    del_result =
      if GiTF.Client.remote?(),
        do: GiTF.Client.delete_quest(id),
        else: GiTF.Missions.delete(id)

    case del_result do
      :ok -> Format.success("Quest #{id} removed.")
      {:error, reason} -> Format.error("Failed to remove mission: #{inspect(reason)}")
    end
  end

  def dispatch(_path, _result, _helpers), do: :not_handled

  # -- Private helpers ---------------------------------------------------------

  defp display_phase_timeline(mission) do
    phases = GiTF.Major.Orchestrator.phases()
    current = Map.get(mission, :current_phase, "pending")
    artifacts = Map.get(mission, :artifacts, %{})

    timeline =
      Enum.map_join(phases, " -> ", fn phase ->
        cond do
          Map.has_key?(artifacts, phase) -> "[#{phase}]"
          phase == current -> "*#{phase}*"
          true -> phase
        end
      end)

    IO.puts("Pipeline: #{timeline}")
    IO.puts("")
  end

  defp display_artifact_summaries(mission) do
    artifacts = Map.get(mission, :artifacts, %{})

    if map_size(artifacts) > 0 do
      IO.puts("Phase Artifacts:")

      Enum.each(artifacts, fn {phase, artifact} ->
        summary =
          case phase do
            "research" ->
              key_files = Map.get(artifact, "key_files", [])

              "#{length(key_files)} key files, stack: #{inspect(Map.get(artifact, "tech_stack", []))}"

            "requirements" ->
              reqs = Map.get(artifact, "functional_requirements", [])
              "#{length(reqs)} functional requirements"

            "design" ->
              comps = Map.get(artifact, "components", [])
              "#{length(comps)} components"

            "review" ->
              if Map.get(artifact, "approved"), do: "Approved", else: "Rejected"

            "planning" when is_list(artifact) ->
              "#{length(artifact)} ops planned"

            "validation" ->
              "Verdict: #{Map.get(artifact, "overall_verdict", "unknown")}"

            _ ->
              "completed"
          end

        IO.puts("  #{phase}: #{summary}")
      end)

      IO.puts("")
    end
  end
end
