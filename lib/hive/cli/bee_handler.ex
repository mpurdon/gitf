defmodule Hive.CLI.BeeHandler do
  @moduledoc """
  CLI handler for bee subcommands.

  Extracted from `Hive.CLI` to reduce the monolithic dispatch file.
  """

  alias Hive.CLI.Format

  def dispatch([:bee, :list], _result, _helpers) do
    case Hive.Bees.list() do
      [] ->
        Format.info("No bees. Bees are spawned when the Queen assigns jobs.")

      bees ->
        headers = ["ID", "Name", "Status", "Job ID", "Context %"]

        rows =
          Enum.map(bees, fn b ->
            context_pct =
              case b.context_percentage do
                nil -> "-"
                pct -> "#{Float.round(pct * 100, 1)}%"
              end

            [b.id, b.name, b.status, b.job_id || "-", context_pct]
          end)

        Format.table(headers, rows)
    end
  end

  def dispatch([:bee, :spawn], result, helpers) do
    job_id = helpers.result_get.(result, :options, :job)
    name = helpers.result_get.(result, :options, :name)

    case helpers.resolve_comb_id.(helpers.result_get.(result, :options, :comb)) do
      {:ok, comb_id} ->
        with {:ok, hive_root} <- Hive.hive_dir(),
             {:ok, comb} <- Hive.Comb.get(comb_id) do
          opts = if name, do: [name: name], else: []

          case Hive.Bees.spawn_detached(job_id, comb.id, hive_root, opts) do
            {:ok, bee} ->
              Format.success("Bee \"#{bee.name}\" spawned (#{bee.id})")

            {:error, reason} ->
              Format.error("Failed to spawn bee: #{inspect(reason)}")
          end
        else
          {:error, :not_in_hive} ->
            Format.error("Not inside a hive workspace. Run `hive init` first.")

          {:error, :not_found} ->
            Format.error("Comb not found: #{comb_id}")

          {:error, reason} ->
            Format.error("Failed: #{inspect(reason)}")
        end

      {:error, :no_comb} ->
        Format.error("No comb specified. Use --comb or set one with `hive comb use`.")
    end
  end

  def dispatch([:bee, :stop], result, helpers) do
    bee_id = helpers.result_get.(result, :options, :id)

    case Hive.Bees.stop(bee_id) do
      :ok ->
        Format.success("Bee #{bee_id} stopped.")

      {:error, :not_found} ->
        Format.error("Bee not found or not running: #{bee_id}")
        Format.info("Hint: use `hive bee list` to see all bees.")
    end
  end

  def dispatch([:bee, :context], result, helpers) do
    bee_id = helpers.result_get.(result, :args, :bee_id)

    case Hive.Runtime.ContextMonitor.get_usage_stats(bee_id) do
      {:ok, stats} ->
        IO.puts("Bee: #{bee_id}")
        IO.puts("Context Usage:")
        IO.puts("  Tokens used:  #{stats.tokens_used}")
        IO.puts("  Tokens limit: #{stats.tokens_limit || "unknown"}")
        IO.puts("  Percentage:   #{Float.round(stats.percentage * 100, 2)}%")
        IO.puts("  Status:       #{stats.status}")
        IO.puts("  Needs handoff: #{stats.needs_handoff}")

      {:error, :not_found} ->
        Format.error("Bee not found: #{bee_id}")
    end
  end

  def dispatch(_path, _result, _helpers), do: :not_handled
end
