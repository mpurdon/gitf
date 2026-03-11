defmodule GiTF.Debrief do
  @moduledoc """
  Post-completion review window.

  After a mission is merged, monitors for regressions by periodically running
  the sector's validation command. If regressions are detected, creates
  follow-up missions and penalizes model trust.
  """

  require Logger
  alias GiTF.Archive

  @review_duration_seconds 3600

  @doc """
  Starts a post-sync review window for a completed mission.

  Inserts a review record that will be checked periodically by the Major.
  """
  @spec start_review(String.t()) :: {:ok, map()} | {:error, term()}
  def start_review(mission_id) do
    with {:ok, mission} <- GiTF.Missions.get(mission_id) do
      review = %{
        mission_id: mission_id,
        quest_name: mission.name,
        sector_id: mission.sector_id,
        status: "active",
        started_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), @review_duration_seconds, :second),
        outcome: nil
      }

      {:ok, stored} = Archive.insert(:debriefs, review)

      # Broadcast alert (best-effort)
      try do
        Phoenix.PubSub.broadcast(
          GiTF.PubSub,
          "section:alerts",
          {:debrief_started, mission_id, mission.name}
        )
      rescue
        _ -> :ok
      end

      Logger.info("Post-review started for mission #{mission_id}, expires in #{@review_duration_seconds}s")

      {:ok, stored}
    end
  end

  @doc """
  Checks for regressions by running the sector's validation command.

  Returns `{:ok, :clean}` or `{:ok, :regression, findings}`.
  """
  @spec check_regressions(String.t()) :: {:ok, :clean} | {:ok, :regression, String.t()} | {:error, term()}
  def check_regressions(mission_id) do
    with {:ok, review} <- get_review(mission_id),
         {:ok, sector} <- Archive.fetch(:sectors, review.sector_id) do

      validation_command = Map.get(sector, :validation_command)

      if is_nil(validation_command) do
        {:ok, :clean}
      else
        task = Task.async(fn ->
          System.cmd("sh", ["-c", validation_command],
            cd: sector.path, stderr_to_stdout: true)
        end)

        case Task.yield(task, 120_000) || Task.exfil(task, 5_000) do
          {:ok, {_output, 0}} ->
            {:ok, :clean}

          {:ok, {output, _exit_code}} ->
            {:ok, :regression, output}

          nil ->
            {:ok, :regression, "validation command timed out"}
        end
      end
    end
  rescue
    e ->
      Logger.warning("Regression check failed for mission #{mission_id}: #{Exception.message(e)}")
      {:error, {:check_failed, Exception.message(e)}}
  end

  @doc """
  Handles a detected regression.

  Creates a follow-up mission, applies trust penalties, and broadcasts an alert.
  """
  @spec handle_regression(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def handle_regression(mission_id, findings) do
    with {:ok, mission} <- GiTF.Missions.get(mission_id) do
      # Create follow-up mission
      {:ok, followup} = GiTF.Missions.create(%{
        goal: "Fix regression from mission \"#{mission.name}\"",
        sector_id: mission.sector_id
      })

      # Apply trust penalty
      GiTF.Trust.apply_regression_penalty(mission_id)

      # Update review record
      update_review(mission_id, %{
        status: "regression_detected",
        outcome: %{
          findings: String.slice(findings, 0, 5000),
          followup_mission_id: followup.id,
          detected_at: DateTime.utc_now()
        }
      })

      # Broadcast alert (best-effort)
      try do
        Phoenix.PubSub.broadcast(
          GiTF.PubSub,
          "section:alerts",
          {:regression_detected, mission_id, followup.id}
        )
      rescue
        _ -> :ok
      end

      Logger.warning("Regression detected for mission #{mission_id}, follow-up mission #{followup.id} created")

      {:ok, followup}
    end
  end

  @doc """
  Closes a review window, recording the outcome.
  """
  @spec close_review(String.t()) :: :ok | {:error, term()}
  def close_review(mission_id) do
    update_review(mission_id, %{
      status: "completed",
      outcome: Map.get(get_review_raw(mission_id) || %{}, :outcome) || %{result: "clean"}
    })

    Logger.info("Post-review closed for mission #{mission_id}")
    :ok
  end

  @doc """
  Returns whether post-review is enabled for a sector.
  """
  @spec enabled?(String.t()) :: boolean()
  def enabled?(sector_id) do
    case Archive.get(:sectors, sector_id) do
      nil -> false
      sector -> Map.get(sector, :debrief, false) == true
    end
  end

  @doc """
  Lists all active (non-expired, non-completed) post-reviews.
  """
  @spec active_reviews() :: [map()]
  def active_reviews do
    Archive.filter(:debriefs, fn r -> r.status == "active" end)
  end

  @doc """
  Returns true if the review window has expired.
  """
  @spec expired?(map()) :: boolean()
  def expired?(review) do
    DateTime.compare(DateTime.utc_now(), review.expires_at) == :gt
  end

  # -- Private ---------------------------------------------------------------

  defp get_review(mission_id) do
    case get_review_raw(mission_id) do
      nil -> {:error, :not_found}
      review -> {:ok, review}
    end
  end

  defp get_review_raw(mission_id) do
    Archive.find_one(:debriefs, fn r -> r.mission_id == mission_id end)
  end

  defp update_review(mission_id, updates) do
    case get_review_raw(mission_id) do
      nil -> :ok
      review ->
        updated = Map.merge(review, updates)
        Archive.put(:debriefs, updated)
    end
  end
end
