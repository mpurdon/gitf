defmodule GiTF.Migrations do
  @moduledoc """
  Schema migration system for the GiTF store.

  Migrations are applied automatically on store initialization to ensure
  the data structure matches the current version.
  """

  alias GiTF.Archive

  @current_version 5

  @doc """
  Run all pending migrations.
  """
  def migrate! do
    current = get_schema_version()

    if current < @current_version do
      Enum.each((current + 1)..@current_version, &run_migration/1)
      set_schema_version(@current_version)
    end

    :ok
  end

  @doc """
  Get the current schema version.
  """
  def get_schema_version do
    case Archive.get(:metadata, "schema_version") do
      nil -> 0
      %{version: version} -> version
    end
  end

  # Private

  defp set_schema_version(version) do
    Archive.put(:metadata, %{id: "schema_version", version: version})
  end

  defp run_migration(1) do
    # Migration 1: Add multi-model support fields to ops
    ops = Archive.all(:ops)

    Enum.each(ops, fn op ->
      updated =
        op
        |> Map.put_new(:op_type, nil)
        |> Map.put_new(:complexity, "moderate")
        |> Map.put_new(:recommended_model, nil)
        |> Map.put_new(:assigned_model, nil)
        |> Map.put_new(:model_selection_reason, nil)
        |> Map.put_new(:verification_criteria, [])
        |> Map.put_new(:estimated_context_tokens, nil)

      Archive.put(:ops, updated)
    end)

    # Add ghosts model tracking
    ghosts = Archive.all(:ghosts)

    Enum.each(ghosts, fn ghost ->
      updated =
        ghost
        |> Map.put_new(:assigned_model, nil)
        |> Map.put_new(:context_tokens_used, 0)
        |> Map.put_new(:context_tokens_limit, nil)
        |> Map.put_new(:context_percentage, 0.0)

      Archive.put(:ghosts, updated)
    end)

    # Initialize context_snapshots collection (empty)
    # The collection will be created automatically on first insert
    :ok
  end

  defp run_migration(2) do
    # Migration 2: Placeholder for future use
    :ok
  end

  defp run_migration(3) do
    # Migration 3: Add mission phase tracking fields
    missions = Archive.all(:missions)

    Enum.each(missions, fn mission ->
      updated =
        mission
        |> Map.put_new(:current_phase, "pending")
        |> Map.put_new(:research_summary, nil)
        |> Map.put_new(:implementation_plan, nil)

      Archive.put(:missions, updated)
    end)

    # Initialize mission_phase_transitions collection (empty)
    # The collection will be created automatically on first insert
    :ok
  end

  defp run_migration(4) do
    # Migration 4: Add research caching collections
    # Initialize sector_research_cache collection (empty)
    # Initialize research_file_index collection (empty)
    # Collections will be created automatically on first insert
    :ok
  end

  defp run_migration(5) do
    # Migration 5: Add verification fields to ops
    ops = Archive.all(:ops)

    Enum.each(ops, fn op ->
      updated =
        op
        |> Map.put_new(:verification_status, "pending")
        |> Map.put_new(:audit_result, nil)
        |> Map.put_new(:verified_at, nil)

      Archive.put(:ops, updated)
    end)

    # Initialize audit_results collection (empty)
    :ok
  end
end
