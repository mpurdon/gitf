defmodule Hive.CLI.QuestHandler do
  @moduledoc """
  CLI handler for quest subcommands.

  Extracted from `Hive.CLI` to reduce the monolithic dispatch file.
  The main CLI module delegates quest-related dispatch calls here.
  """

  alias Hive.CLI.Format

  def dispatch([:quest, :new], result, helpers) do
    goal = helpers.result_get.(result, :args, :goal)

    if Hive.Client.remote?() do
      comb_opt = helpers.result_get.(result, :options, :comb)
      attrs = if comb_opt, do: %{goal: goal, comb_id: comb_opt}, else: %{goal: goal}

      case Hive.Client.create_quest(attrs) do
        {:ok, quest} ->
          Format.success("Quest created: #{quest.name} (#{quest.id})")
          Format.info("Starting quest execution on remote server...")

          case Hive.Client.start_quest(quest.id) do
            {:ok, data} ->
              phase = if is_map(data), do: data[:phase], else: data
              Format.success("Quest #{quest.id} is now in #{phase} phase.")

            {:error, reason} ->
              Format.warn("Could not auto-start: #{inspect(reason)}")
          end

        {:error, reason} ->
          Format.error("Failed to create quest: #{inspect(reason)}")
      end
    else
      discovery? = goal == nil or goal == ""

      {quest_result, _comb_id} =
        case helpers.resolve_comb_id.(helpers.result_get.(result, :options, :comb)) do
          {:ok, cid} -> {Hive.Quests.create(%{goal: goal || "New quest", comb_id: cid}), cid}
          {:error, :no_comb} -> {Hive.Quests.create(%{goal: goal || "New quest"}), nil}
        end

      case quest_result do
        {:ok, quest} ->
          Format.success("Quest created: #{quest.name} (#{quest.id})")
          opts = if discovery?, do: [interactive_goal: true], else: []
          Hive.CLI.PlanHandler.start_interactive_planning(quest, opts)

        {:error, reason} ->
          Format.error("Failed to create quest: #{inspect(reason)}")
      end
    end
  end

  def dispatch([:quest, :list], _result, _helpers) do
    quests =
      if Hive.Client.remote?() do
        case Hive.Client.list_quests() do
          {:ok, q} -> q
          {:error, reason} -> Format.error("Remote error: #{inspect(reason)}"); []
        end
      else
        Hive.Quests.list()
      end

    case quests do
      [] ->
        Format.info("No quests yet. Create one with `hive quest new \"<goal>\"`")

      quests ->
        headers = ["ID", "Name", "Phase", "Status", "Jobs", "Created"]

        rows =
          Enum.map(quests, fn q ->
            job_summary =
              case q[:jobs] do
                nil -> "-"
                jobs -> "#{length(jobs)}"
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

  def dispatch([:quest, :show], result, helpers) do
    id = helpers.result_get.(result, :args, :id)

    quest_result =
      if Hive.Client.remote?(),
        do: Hive.Client.get_quest(id),
        else: Hive.Quests.get(id)

    case quest_result do
      {:ok, quest} ->
        IO.puts("Quest: #{quest.name}")
        IO.puts("ID:     #{quest.id}")
        IO.puts("Status: #{quest.status}")
        IO.puts("Phase:  #{quest[:current_phase] || "pending"}")
        IO.puts("")

        unless Hive.Client.remote?() do
          # Phase timeline
          display_phase_timeline(quest)

          # Artifact summaries
          display_artifact_summaries(quest)
        end

        # Jobs table
        case quest[:jobs] do
          nil ->
            Format.info("No jobs yet.")

          [] ->
            Format.info("No jobs yet.")

          jobs ->
            # Separate phase jobs from implementation jobs
            phase_jobs = Enum.filter(jobs, & &1[:phase_job])
            impl_jobs = Enum.reject(jobs, & &1[:phase_job])

            if impl_jobs != [] do
              IO.puts("Implementation Jobs:")
              headers = ["Job ID", "Title", "Status", "Bee", "Model"]

              rows =
                Enum.map(impl_jobs, fn j ->
                  [
                    j.id,
                    String.slice(to_string(j.title), 0, 50),
                    j.status,
                    j[:bee_id] || "-",
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

  def dispatch([:quest, :remove], result, helpers) do
    id = helpers.result_get.(result, :args, :id)

    del_result =
      if Hive.Client.remote?(),
        do: Hive.Client.delete_quest(id),
        else: Hive.Quests.delete(id)

    case del_result do
      :ok -> Format.success("Quest #{id} removed.")
      {:error, reason} -> Format.error("Failed to remove quest: #{inspect(reason)}")
    end
  end

  def dispatch(_path, _result, _helpers), do: :not_handled

  # -- Private helpers ---------------------------------------------------------

  defp display_phase_timeline(quest) do
    phases = Hive.Queen.Orchestrator.phases()
    current = Map.get(quest, :current_phase, "pending")
    artifacts = Map.get(quest, :artifacts, %{})

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

  defp display_artifact_summaries(quest) do
    artifacts = Map.get(quest, :artifacts, %{})

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
              "#{length(artifact)} jobs planned"

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
