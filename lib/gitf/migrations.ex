defmodule GiTF.Migrations do
  @moduledoc """
  Schema migration system for the GiTF store.

  Migrations are applied automatically on store initialization to ensure
  the data structure matches the current version.
  """

  alias GiTF.Archive

  @current_version 9

  @doc """
  Run all pending migrations.
  """
  def migrate! do
    current = get_schema_version()

    cond do
      current > @current_version ->
        # A rolled-back release reading a newer store must fail loudly at
        # boot, not run against a schema it doesn't understand and scatter
        # KeyErrors through drift/model-routing readers.
        raise "Store schema is v#{current} but this release only knows v#{@current_version} — " <>
                "refusing to run a downgraded release against a newer store. " <>
                "Deploy the newer release, or restore a matching store backup."

      current < @current_version ->
        Enum.each((current + 1)..@current_version, &run_migration/1)
        set_schema_version(@current_version)

      true ->
        :ok
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

  defp run_migration(6) do
    # Migration 6: Add priority fields to missions and ops
    missions = Archive.all(:missions)

    Enum.each(missions, fn mission ->
      updated =
        mission
        |> Map.put_new(:priority, :normal)
        |> Map.put_new(:priority_source, :default)
        |> Map.put_new(:priority_set_at, Map.get(mission, :inserted_at, DateTime.utc_now()))

      Archive.put(:missions, updated)
    end)

    ops = Archive.all(:ops)

    Enum.each(ops, fn op ->
      updated = Map.put_new(op, :priority, :normal)
      Archive.put(:ops, updated)
    end)

    :ok
  end

  defp run_migration(7) do
    # Migration 7: Add drift detection fields to shells
    shells = Archive.all(:shells)

    Enum.each(shells, fn shell ->
      updated =
        shell
        |> Map.put_new(:base_commit_sha, nil)
        |> Map.put_new(:base_ref, nil)
        |> Map.put_new(:drift_state, :unknown)
        |> Map.put_new(:drift_checked_at, nil)
        |> Map.put_new(:drift_meta, nil)

      Archive.put(:shells, updated)
    end)

    :ok
  end

  defp run_migration(8) do
    # Migration 8: Add phase_advance_seq to missions for idempotency guards
    missions = Archive.all(:missions)

    Enum.each(missions, fn mission ->
      updated = Map.put_new(mission, :phase_advance_seq, 0)
      Archive.put(:missions, updated)
    end)

    :ok
  end

  defp run_migration(9) do
    # Migration 9: Backfill validation_timeout_ms on sectors. The field was read
    # by GiTF.Validator but written nowhere, so every sector silently took the
    # 120s default. cora's command — `npm ci && … npm run typecheck && bash
    # …/probes/cora-smoke.sh` — is a cold npm install plus a Tauri build-and-
    # launch probe and cannot finish in 120s, so every op came back :timeout and
    # manufactured six fix ghosts that merge-conflicted and killed the mission.
    sectors = Archive.all(:sectors)

    Enum.each(sectors, fn sector ->
      # Guarded rather than Map.put_new/3 so re-running this never walks the
      # filesystem for a sector an operator has already tuned.
      unless Map.has_key?(sector, :validation_timeout_ms) do
        Archive.put(
          :sectors,
          Map.put(sector, :validation_timeout_ms, derive_sector_timeout(sector))
        )
      end
    end)

    :ok
  end

  # Re-detect against the live checkout when it is still there, but always feed
  # the STORED command in: that is where the `npm ci` and `probes/` markers
  # live, and the detector would never have suggested them itself. A sector
  # whose path has since vanished still gets the command-shape budget.
  defp derive_sector_timeout(sector) do
    path = Map.get(sector, :path)

    project_info =
      if is_binary(path) and File.dir?(path) do
        GiTF.Onboarding.Detector.detect(path)
      else
        %{}
      end

    GiTF.Onboarding.Detector.derive_validation_timeout_ms(
      project_info,
      Map.get(sector, :validation_command)
    )
  end
end
