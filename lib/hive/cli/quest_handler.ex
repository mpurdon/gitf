defmodule Hive.CLI.QuestHandler do
  @moduledoc """
  CLI handler for quest subcommands.

  Extracted from `Hive.CLI` to reduce the monolithic dispatch file.
  The main CLI module delegates quest-related dispatch calls here.
  """

  alias Hive.CLI.Format

  def dispatch([:quest, :new], result, helpers) do
    goal = helpers.result_get.(result, :args, :goal)

    case helpers.resolve_comb_id.(helpers.result_get.(result, :options, :comb)) do
      {:ok, comb_id} ->
        case Hive.Quests.create(goal, comb_id) do
          {:ok, quest} ->
            Format.success("Quest created: #{quest.name} (#{quest.id})")

          {:error, reason} ->
            Format.error("Failed to create quest: #{inspect(reason)}")
        end

      {:error, :no_comb} ->
        Format.error("No comb specified. Use --comb or set one with `hive comb use`.")
    end
  end

  def dispatch([:quest, :list], _result, _helpers) do
    case Hive.Quests.list() do
      [] ->
        Format.info("No quests yet. Create one with `hive quest new \"<goal>\"`")

      quests ->
        headers = ["ID", "Name", "Status", "Jobs", "Created"]

        rows =
          Enum.map(quests, fn q ->
            job_summary =
              case q[:jobs] do
                nil -> "-"
                jobs -> "#{length(jobs)}"
              end

            [q.id, q.name, q.status, job_summary, Calendar.strftime(q.inserted_at, "%Y-%m-%d")]
          end)

        Format.table(headers, rows)
    end
  end

  def dispatch([:quest, :show], result, helpers) do
    id = helpers.result_get.(result, :args, :id)

    case Hive.Quests.get(id) do
      {:ok, quest} ->
        IO.puts("Quest: #{quest.name}")
        IO.puts("ID:     #{quest.id}")
        IO.puts("Status: #{quest.status}")
        IO.puts("")

        case quest[:jobs] do
          nil ->
            Format.info("No jobs yet.")

          jobs ->
            headers = ["Job ID", "Title", "Status", "Bee", "Model"]

            rows =
              Enum.map(jobs, fn j ->
                [
                  j.id,
                  String.slice(j.title, 0, 50),
                  j.status,
                  j.bee_id || "-",
                  j[:assigned_model] || "-"
                ]
              end)

            Format.table(headers, rows)
        end

      {:error, :not_found} ->
        Format.error("Quest not found: #{id}")
    end
  end

  def dispatch([:quest, :delete], result, helpers) do
    id = helpers.result_get.(result, :args, :id)

    case Hive.Quests.delete(id) do
      :ok -> Format.success("Quest #{id} deleted.")
      {:error, reason} -> Format.error("Failed to delete quest: #{inspect(reason)}")
    end
  end

  def dispatch(_path, _result, _helpers), do: :not_handled
end
