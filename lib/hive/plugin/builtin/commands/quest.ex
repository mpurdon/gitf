defmodule Hive.Plugin.Builtin.Commands.Quest do
  @moduledoc "Built-in /quest command. Create, list, and show quests."

  use Hive.Plugin, type: :command

  @impl true
  def name, do: "quest"

  @impl true
  def description, do: "Manage quests (new, list, show)"

  @impl true
  def execute(args, ctx) do
    case String.trim(args) |> String.split(" ", parts: 2) do
      ["new", goal] -> do_new(goal, ctx)
      ["new" | _] -> send_output(ctx, "Usage: /quest new <goal>")
      ["list" | _] -> do_list(ctx)
      ["show", id] -> do_show(id, ctx)
      ["show" | _] -> send_output(ctx, "Usage: /quest show <id>")
      [other | _] -> send_output(ctx, "Unknown subcommand: #{other}. Try: new, list, show")
      _ -> do_list(ctx)
    end

    :ok
  end

  @impl true
  def completions(partial) do
    subs = ["new", "list", "show"]
    Enum.filter(subs, &String.starts_with?(&1, partial))
  end

  defp do_new(goal, ctx) do
    case Hive.Quests.create(%{goal: goal}) do
      {:ok, quest} ->
        send_output(ctx, "Quest \"#{quest.name}\" created (#{quest.id})")

      {:error, reason} ->
        send_output(ctx, "Failed: #{inspect(reason)}")
    end
  end

  defp do_list(ctx) do
    case Hive.Quests.list() do
      [] ->
        send_output(ctx, "No quests. Use /quest new <goal> to create one.")

      quests ->
        lines =
          Enum.map(quests, fn q ->
            "  #{q.id}  #{q.name}  [#{q.status}]"
          end)

        send_output(ctx, ["Quests:", "" | lines] |> Enum.join("\n"))
    end
  end

  defp do_show(id, ctx) do
    case Hive.Quests.get(id) do
      {:ok, quest} ->
        council_line =
          if quest[:council_id] do
            case Hive.Council.get(quest.council_id) do
              {:ok, c} -> "Council: #{c.domain} (#{c.id})"
              _ -> "Council: #{quest.council_id}"
            end
          end

        lines =
          [
            "Quest: #{quest.name} (#{quest.id})",
            "Status: #{quest.status}",
            council_line,
            "Goal: #{quest[:goal] || "-"}"
          ]
          |> Enum.reject(&is_nil/1)

        jobs_lines =
          case quest.jobs do
            [] ->
              ["", "No jobs."]

            jobs ->
              ["", "Jobs:"] ++
                Enum.map(jobs, fn j ->
                  "  #{j.id}  #{j.title}  [#{j.status}]  #{j.bee_id || "-"}"
                end)
          end

        send_output(ctx, Enum.join(lines ++ jobs_lines, "\n"))

      {:error, :not_found} ->
        send_output(ctx, "Quest not found: #{id}")
    end
  end

  defp send_output(%{pid: pid}, text) when is_pid(pid), do: send(pid, {:command_output, text})
  defp send_output(_ctx, text), do: IO.puts(text)
end
