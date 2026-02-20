defmodule Hive.Migrations do
  @moduledoc """
  Schema migration system for the Hive store.
  
  Migrations are applied automatically on store initialization to ensure
  the data structure matches the current version.
  """

  alias Hive.Store

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
    case Store.get(:metadata, "schema_version") do
      nil -> 0
      %{version: version} -> version
    end
  end

  # Private

  defp set_schema_version(version) do
    Store.put(:metadata, %{id: "schema_version", version: version})
  end

  defp run_migration(1) do
    # Migration 1: Add multi-model support fields to jobs
    jobs = Store.all(:jobs)

    Enum.each(jobs, fn job ->
      updated =
        job
        |> Map.put_new(:job_type, nil)
        |> Map.put_new(:complexity, "moderate")
        |> Map.put_new(:recommended_model, nil)
        |> Map.put_new(:assigned_model, nil)
        |> Map.put_new(:model_selection_reason, nil)
        |> Map.put_new(:verification_criteria, [])
        |> Map.put_new(:estimated_context_tokens, nil)

      Store.put(:jobs, updated)
    end)

    # Add bees model tracking
    bees = Store.all(:bees)

    Enum.each(bees, fn bee ->
      updated =
        bee
        |> Map.put_new(:assigned_model, nil)
        |> Map.put_new(:context_tokens_used, 0)
        |> Map.put_new(:context_tokens_limit, nil)
        |> Map.put_new(:context_percentage, 0.0)

      Store.put(:bees, updated)
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
    # Migration 3: Add quest phase tracking fields
    quests = Store.all(:quests)

    Enum.each(quests, fn quest ->
      updated =
        quest
        |> Map.put_new(:current_phase, "pending")
        |> Map.put_new(:research_summary, nil)
        |> Map.put_new(:implementation_plan, nil)

      Store.put(:quests, updated)
    end)

    # Initialize quest_phase_transitions collection (empty)
    # The collection will be created automatically on first insert
    :ok
  end

  defp run_migration(4) do
    # Migration 4: Add research caching collections
    # Initialize comb_research_cache collection (empty)
    # Initialize research_file_index collection (empty)
    # Collections will be created automatically on first insert
    :ok
  end

  defp run_migration(5) do
    # Migration 5: Add verification fields to jobs
    jobs = Store.all(:jobs)

    Enum.each(jobs, fn job ->
      updated =
        job
        |> Map.put_new(:verification_status, "pending")
        |> Map.put_new(:verification_result, nil)
        |> Map.put_new(:verified_at, nil)

      Store.put(:jobs, updated)
    end)

    # Initialize verification_results collection (empty)
    :ok
  end

  defp run_migration(6) do
    # Migration 6: Placeholder for future use
    :ok
  end
end
