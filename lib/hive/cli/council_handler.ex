defmodule Hive.CLI.CouncilHandler do
  @moduledoc """
  CLI handler for council subcommands.

  Extracted from `Hive.CLI` to reduce the monolithic dispatch file.
  """

  alias Hive.CLI.Format

  def dispatch([:council, :create], result, helpers) do
    domain = helpers.result_get.(result, :args, :domain)
    experts = helpers.result_get.(result, :options, :experts)

    opts = if experts, do: [experts: experts], else: []

    Hive.CLI.Progress.with_spinner("Discovering experts for \"#{domain}\"...", fn ->
      Hive.Council.create(domain, opts)
    end)
    |> case do
      {:ok, council} ->
        Format.success("Council created: #{council.id}")
        IO.puts("Domain: #{council.domain}")
        IO.puts("Experts: #{length(council.experts)}")

        Enum.each(council.experts, fn e ->
          IO.puts("  #{e.key}: #{e.name}")
        end)

      {:error, reason} ->
        Format.error("Failed to create council: #{inspect(reason)}")
    end
  end

  def dispatch([:council, :list], _result, _helpers) do
    councils = Hive.Store.all(:councils)

    case councils do
      [] ->
        Format.info("No councils yet. Create one with `hive council create \"<domain>\"`")

      _ ->
        headers = ["ID", "Domain", "Experts", "Created"]

        rows =
          Enum.map(councils, fn c ->
            expert_count = length(Map.get(c, :experts, []))
            [c.id, c.domain, "#{expert_count}", Calendar.strftime(c.inserted_at, "%Y-%m-%d")]
          end)

        Format.table(headers, rows)
    end
  end

  def dispatch([:council, :show], result, helpers) do
    id = helpers.result_get.(result, :args, :id)

    case Hive.Store.get(:councils, id) do
      nil ->
        Format.error("Council not found: #{id}")

      council ->
        IO.puts("Council: #{council.id}")
        IO.puts("Domain:  #{council.domain}")
        IO.puts("")

        Enum.each(council.experts, fn e ->
          IO.puts("  #{e.key}: #{e.name}")
          IO.puts("    Focus:         #{e.focus}")
          IO.puts("    Philosophy:    #{e.philosophy}")
          IO.puts("    Contributions: #{Enum.join(e.contributions, ", ")}")
          IO.puts("")
        end)
    end
  end

  def dispatch([:council, :delete], result, helpers) do
    id = helpers.result_get.(result, :args, :id)

    case Hive.Council.delete(id) do
      :ok -> Format.success("Council #{id} deleted.")
      {:error, reason} -> Format.error("Failed: #{inspect(reason)}")
    end
  end

  def dispatch([:council, :preview], result, helpers) do
    domain = helpers.result_get.(result, :args, :domain)
    experts = helpers.result_get.(result, :options, :experts)

    opts = if experts, do: [experts: experts], else: []

    Format.info("Discovering experts for \"#{domain}\"...")

    case Hive.Council.preview(domain, opts) do
      {:ok, experts} ->
        IO.puts("")
        IO.puts("Identified #{length(experts)} expert(s):")
        IO.puts("")

        Enum.each(experts, fn e ->
          IO.puts("  #{e.key}: #{e.name}")
          IO.puts("    Focus:         #{e.focus}")
          IO.puts("    Philosophy:    #{e.philosophy}")
          IO.puts("    Contributions: #{Enum.join(e.contributions, ", ")}")
          IO.puts("")
        end)

      {:error, reason} ->
        Format.error("Preview failed: #{inspect(reason)}")
    end
  end

  def dispatch(_path, _result, _helpers), do: :not_handled
end
