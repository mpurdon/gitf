defmodule Hive.Plugin.Builtin.Commands.Council do
  @moduledoc "Built-in /council command. Create, list, show, apply, and preview councils."

  use Hive.Plugin, type: :command

  @impl true
  def name, do: "council"

  @impl true
  def description, do: "Manage expert councils (create, list, show, apply, preview)"

  @impl true
  def execute(args, ctx) do
    case String.trim(args) |> String.split(" ", parts: 3) do
      ["create", domain] -> do_create(domain, ctx)
      ["create" | _] -> send_output(ctx, "Usage: /council create <domain>")
      ["list" | _] -> do_list(ctx)
      ["show", id] -> do_show(id, ctx)
      ["show" | _] -> send_output(ctx, "Usage: /council show <id>")
      ["delete", id] -> do_delete(id, ctx)
      ["delete" | _] -> send_output(ctx, "Usage: /council delete <id>")
      ["apply", id, rest] -> do_apply(id, rest, ctx)
      ["apply" | _] -> send_output(ctx, "Usage: /council apply <council-id> --quest <quest-id>")
      ["preview", domain] -> do_preview(domain, ctx)
      ["preview" | _] -> send_output(ctx, "Usage: /council preview <domain>")
      [other | _] -> send_output(ctx, "Unknown: #{other}. Try: create, list, show, apply, preview")
      _ -> do_list(ctx)
    end

    :ok
  end

  @impl true
  def completions(partial) do
    subs = ["create", "list", "show", "delete", "apply", "preview"]
    Enum.filter(subs, &String.starts_with?(&1, partial))
  end

  defp do_create(domain, ctx) do
    send_output(ctx, "Researching experts for \"#{domain}\"... (this may take a minute)")

    case Hive.Council.create(domain) do
      {:ok, council} ->
        expert_lines =
          Enum.map(council.experts, fn e ->
            "  #{e.key}: #{e.name} — #{e.focus}"
          end)

        lines = ["Council \"#{council.domain}\" created (#{council.id})", "" | expert_lines]
        send_output(ctx, Enum.join(lines, "\n"))

      {:error, {:already_exists, id}} ->
        send_output(ctx, "Council already exists (#{id})")

      {:error, reason} ->
        send_output(ctx, "Failed: #{inspect(reason)}")
    end
  end

  defp do_list(ctx) do
    case Hive.Council.list() do
      [] ->
        send_output(ctx, "No councils. Use /council create <domain> to create one.")

      councils ->
        lines =
          Enum.map(councils, fn c ->
            "  #{c.id}  #{c.name}  [#{c.status}]  #{length(c.experts)} experts"
          end)

        send_output(ctx, ["Councils:", "" | lines] |> Enum.join("\n"))
    end
  end

  defp do_show(id, ctx) do
    case Hive.Council.get(id) do
      {:ok, council} ->
        lines = [
          "Council: #{council.domain} (#{council.id})",
          "Status: #{council.status}",
          "Experts: #{length(council.experts)}",
          ""
        ]

        expert_lines =
          Enum.flat_map(council.experts, fn e ->
            [
              "  #{e.key}: #{e.name}",
              "    Focus: #{e.focus}",
              "    Philosophy: #{e.philosophy}",
              ""
            ]
          end)

        send_output(ctx, Enum.join(lines ++ expert_lines, "\n"))

      {:error, :not_found} ->
        send_output(ctx, "Council not found: #{id}")
    end
  end

  defp do_delete(id, ctx) do
    case Hive.Council.delete(id) do
      :ok -> send_output(ctx, "Council #{id} deleted.")
      {:error, :not_found} -> send_output(ctx, "Council not found: #{id}")
    end
  end

  defp do_apply(council_id, rest, ctx) do
    # Parse --quest <quest-id> from rest
    case parse_quest_flag(rest) do
      {:ok, quest_id} ->
        case Hive.Council.apply_to_quest(council_id, quest_id) do
          {:ok, %{wave_count: waves, jobs_created: jobs}} ->
            send_output(ctx, "Council applied: #{jobs} review jobs in #{waves} wave(s)")

          {:error, reason} ->
            send_output(ctx, "Failed: #{inspect(reason)}")
        end

      :error ->
        send_output(ctx, "Usage: /council apply <council-id> --quest <quest-id>")
    end
  end

  defp do_preview(domain, ctx) do
    send_output(ctx, "Discovering experts for \"#{domain}\"...")

    case Hive.Council.preview(domain) do
      {:ok, experts} ->
        lines =
          Enum.flat_map(experts, fn e ->
            [
              "  #{e.key}: #{e.name}",
              "    Focus: #{e.focus}",
              "    Contributions: #{Enum.join(e.contributions, ", ")}",
              ""
            ]
          end)

        send_output(ctx, ["Found #{length(experts)} expert(s):", "" | lines] |> Enum.join("\n"))

      {:error, reason} ->
        send_output(ctx, "Preview failed: #{inspect(reason)}")
    end
  end

  defp parse_quest_flag(rest) do
    parts = String.split(rest)

    case parts do
      ["--quest", quest_id | _] -> {:ok, quest_id}
      _ -> :error
    end
  end

  defp send_output(%{pid: pid}, text) when is_pid(pid), do: send(pid, {:command_output, text})
  defp send_output(_ctx, text), do: IO.puts(text)
end
