defmodule GiTF.CLI.GhostHandler do
  @moduledoc """
  CLI handler for ghost subcommands.

  Extracted from `GiTF.CLI` to reduce the monolithic dispatch file.
  """

  alias GiTF.CLI.Format

  def dispatch([:ghost, :list], _result, _helpers) do
    ghosts =
      if GiTF.Client.remote?() do
        case GiTF.Client.list_bees() do
          {:ok, b} -> b
          {:error, reason} -> Format.error("Remote error: #{inspect(reason)}"); []
        end
      else
        GiTF.Ghosts.list()
      end

    case ghosts do
      [] ->
        Format.info("No ghosts. Bees are spawned when the Major assigns ops.")

      ghosts ->
        headers = ["ID", "Name", "Status", "Job ID", "Context %"]

        rows =
          Enum.map(ghosts, fn b ->
            context_pct =
              case b[:context_percentage] do
                nil -> "-"
                pct when is_number(pct) -> "#{Float.round(pct * 100, 1)}%"
                _ -> "-"
              end

            [b.id, b.name, b.status, b[:op_id] || "-", context_pct]
          end)

        Format.table(headers, rows)
    end
  end

  def dispatch([:ghost, :spawn], result, helpers) do
    if GiTF.Client.remote?() do
      Format.error("Bee spawning is a server-side operation. Run it on the server directly.")
    else
      op_id = helpers.result_get.(result, :options, :op)
      name = helpers.result_get.(result, :options, :name)

      case helpers.resolve_comb_id.(helpers.result_get.(result, :options, :sector)) do
        {:ok, sector_id} ->
          with {:ok, gitf_root} <- GiTF.gitf_dir(),
               {:ok, sector} <- GiTF.Sector.get(sector_id) do
            opts = if name, do: [name: name], else: []

            case GiTF.Ghosts.spawn_detached(op_id, sector.id, gitf_root, opts) do
              {:ok, ghost} ->
                Format.success("Bee \"#{ghost.name}\" spawned (#{ghost.id})")

              {:error, reason} ->
                Format.error("Failed to spawn ghost: #{inspect(reason)}")
            end
          else
            {:error, :not_in_gitf} ->
              Format.error("Not inside a gitf workspace. Run `gitf init` first.")

            {:error, :not_found} ->
              Format.error("Comb not found: #{sector_id}")

            {:error, reason} ->
              Format.error("Failed: #{inspect(reason)}")
          end

        {:error, :no_comb} ->
          Format.error("No sector specified. Use --sector or set one with `gitf sector use`.")
      end
    end
  end

  def dispatch([:ghost, :stop], result, helpers) do
    ghost_id = helpers.result_get.(result, :options, :id)

    stop_result =
      if GiTF.Client.remote?(),
        do: GiTF.Client.stop_ghost(ghost_id),
        else: GiTF.Ghosts.stop(ghost_id)

    case stop_result do
      :ok ->
        Format.success("Bee #{ghost_id} stopped.")

      {:error, :not_found} ->
        Format.error("Bee not found or not running: #{ghost_id}")
        Format.info("Hint: use `gitf ghost list` to see all ghosts.")
    end
  end

  def dispatch([:ghost, :context], result, helpers) do
    ghost_id = helpers.result_get.(result, :args, :ghost_id)

    case GiTF.Runtime.ContextMonitor.get_usage_stats(ghost_id) do
      {:ok, stats} ->
        IO.puts("Bee: #{ghost_id}")
        IO.puts("Context Usage:")
        IO.puts("  Tokens used:  #{stats.tokens_used}")
        IO.puts("  Tokens limit: #{stats.tokens_limit || "unknown"}")
        IO.puts("  Percentage:   #{Float.round(stats.percentage * 100, 2)}%")
        IO.puts("  Status:       #{stats.status}")
        IO.puts("  Needs transfer: #{stats.needs_handoff}")

      {:error, :not_found} ->
        Format.error("Bee not found: #{ghost_id}")
    end
  end

  def dispatch(_path, _result, _helpers), do: :not_handled
end
