defmodule GiTF.Plugin.Builtin.Commands.Bee do
  @moduledoc "Built-in /ghost command. List, spawn, and stop ghosts."

  use GiTF.Plugin, type: :command

  @impl true
  def name, do: "ghost"

  @impl true
  def description, do: "Manage ghosts (list, spawn, stop)"

  @impl true
  def execute(args, ctx) do
    case String.trim(args) |> String.split(" ", parts: 3) do
      ["list" | _] -> do_list(ctx)
      ["spawn", "--job", job_id] -> do_spawn(job_id, ctx)
      ["spawn" | _] -> send_output(ctx, "Usage: /ghost spawn --job <job_id>")
      ["stop", ghost_id] -> do_stop(ghost_id, ctx)
      ["stop" | _] -> send_output(ctx, "Usage: /ghost stop <ghost_id>")
      [other | _] -> send_output(ctx, "Unknown subcommand: #{other}. Try: list, spawn, stop")
      _ -> do_list(ctx)
    end

    :ok
  end

  @impl true
  def completions(partial) do
    subs = ["list", "spawn", "stop"]
    Enum.filter(subs, &String.starts_with?(&1, partial))
  end

  defp do_list(ctx) do
    case GiTF.Ghosts.list() do
      [] ->
        send_output(ctx, "No ghosts. Bees are spawned when jobs are assigned.")

      ghosts ->
        lines =
          Enum.map(ghosts, fn b ->
            "  #{b.id}  #{b.name}  [#{b.status}]  #{b.job_id || "-"}"
          end)

        send_output(ctx, ["Bees:", "" | lines] |> Enum.join("\n"))
    end
  end

  defp do_spawn(job_id, ctx) do
    with {:ok, gitf_root} <- GiTF.gitf_dir(),
         {:ok, job} <- GiTF.Jobs.get(job_id),
         comb_id when is_binary(comb_id) <- job.comb_id do
      case GiTF.Ghosts.spawn_detached(job_id, comb_id, gitf_root) do
        {:ok, ghost} ->
          send_output(ctx, "Bee \"#{ghost.name}\" spawned (#{ghost.id})")

        {:error, reason} ->
          send_output(ctx, "Failed to spawn: #{inspect(reason)}")
      end
    else
      {:error, reason} -> send_output(ctx, "Error: #{inspect(reason)}")
      nil -> send_output(ctx, "Job has no comb_id")
    end
  end

  defp do_stop(ghost_id, ctx) do
    case GiTF.Ghosts.stop(ghost_id) do
      :ok -> send_output(ctx, "Bee #{ghost_id} stopped.")
      {:error, :not_found} -> send_output(ctx, "Bee not found: #{ghost_id}")
    end
  end

  defp send_output(%{pid: pid}, text) when is_pid(pid), do: send(pid, {:command_output, text})
  defp send_output(_ctx, text), do: IO.puts(text)
end
