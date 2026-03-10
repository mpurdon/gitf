defmodule Hive.PostReview do
  @moduledoc """
  Post-completion review window.

  After a quest is merged, monitors for regressions by periodically running
  the comb's validation command. If regressions are detected, creates
  follow-up quests and penalizes model reputation.
  """

  require Logger
  alias Hive.Store

  @review_duration_seconds 3600

  @doc """
  Starts a post-merge review window for a completed quest.

  Inserts a review record that will be checked periodically by the Queen.
  """
  @spec start_review(String.t()) :: {:ok, map()} | {:error, term()}
  def start_review(quest_id) do
    with {:ok, quest} <- Hive.Quests.get(quest_id) do
      review = %{
        quest_id: quest_id,
        quest_name: quest.name,
        comb_id: quest.comb_id,
        status: "active",
        started_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), @review_duration_seconds, :second),
        outcome: nil
      }

      {:ok, stored} = Store.insert(:post_reviews, review)

      # Broadcast alert (best-effort)
      try do
        Phoenix.PubSub.broadcast(
          Hive.PubSub,
          "hive:alerts",
          {:post_review_started, quest_id, quest.name}
        )
      rescue
        _ -> :ok
      end

      Logger.info("Post-review started for quest #{quest_id}, expires in #{@review_duration_seconds}s")

      {:ok, stored}
    end
  end

  @doc """
  Checks for regressions by running the comb's validation command.

  Returns `{:ok, :clean}` or `{:ok, :regression, findings}`.
  """
  @spec check_regressions(String.t()) :: {:ok, :clean} | {:ok, :regression, String.t()} | {:error, term()}
  def check_regressions(quest_id) do
    with {:ok, review} <- get_review(quest_id),
         {:ok, comb} <- Store.fetch(:combs, review.comb_id) do

      validation_command = Map.get(comb, :validation_command)

      if is_nil(validation_command) do
        {:ok, :clean}
      else
        task = Task.async(fn ->
          System.cmd("sh", ["-c", validation_command],
            cd: comb.path, stderr_to_stdout: true)
        end)

        case Task.yield(task, 120_000) || Task.shutdown(task, 5_000) do
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
      Logger.warning("Regression check failed for quest #{quest_id}: #{Exception.message(e)}")
      {:error, {:check_failed, Exception.message(e)}}
  end

  @doc """
  Handles a detected regression.

  Creates a follow-up quest, applies reputation penalties, and broadcasts an alert.
  """
  @spec handle_regression(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def handle_regression(quest_id, findings) do
    with {:ok, quest} <- Hive.Quests.get(quest_id) do
      # Create follow-up quest
      {:ok, followup} = Hive.Quests.create(%{
        goal: "Fix regression from quest \"#{quest.name}\"",
        comb_id: quest.comb_id
      })

      # Apply reputation penalty
      Hive.Reputation.apply_regression_penalty(quest_id)

      # Update review record
      update_review(quest_id, %{
        status: "regression_detected",
        outcome: %{
          findings: String.slice(findings, 0, 5000),
          followup_quest_id: followup.id,
          detected_at: DateTime.utc_now()
        }
      })

      # Broadcast alert (best-effort)
      try do
        Phoenix.PubSub.broadcast(
          Hive.PubSub,
          "hive:alerts",
          {:regression_detected, quest_id, followup.id}
        )
      rescue
        _ -> :ok
      end

      Logger.warning("Regression detected for quest #{quest_id}, follow-up quest #{followup.id} created")

      {:ok, followup}
    end
  end

  @doc """
  Closes a review window, recording the outcome.
  """
  @spec close_review(String.t()) :: :ok | {:error, term()}
  def close_review(quest_id) do
    update_review(quest_id, %{
      status: "completed",
      outcome: Map.get(get_review_raw(quest_id) || %{}, :outcome) || %{result: "clean"}
    })

    Logger.info("Post-review closed for quest #{quest_id}")
    :ok
  end

  @doc """
  Returns whether post-review is enabled for a comb.
  """
  @spec enabled?(String.t()) :: boolean()
  def enabled?(comb_id) do
    case Store.get(:combs, comb_id) do
      nil -> false
      comb -> Map.get(comb, :post_review, false) == true
    end
  end

  @doc """
  Lists all active (non-expired, non-completed) post-reviews.
  """
  @spec active_reviews() :: [map()]
  def active_reviews do
    Store.filter(:post_reviews, fn r -> r.status == "active" end)
  end

  @doc """
  Returns true if the review window has expired.
  """
  @spec expired?(map()) :: boolean()
  def expired?(review) do
    DateTime.compare(DateTime.utc_now(), review.expires_at) == :gt
  end

  # -- Private ---------------------------------------------------------------

  defp get_review(quest_id) do
    case get_review_raw(quest_id) do
      nil -> {:error, :not_found}
      review -> {:ok, review}
    end
  end

  defp get_review_raw(quest_id) do
    Store.find_one(:post_reviews, fn r -> r.quest_id == quest_id end)
  end

  defp update_review(quest_id, updates) do
    case get_review_raw(quest_id) do
      nil -> :ok
      review ->
        updated = Map.merge(review, updates)
        Store.put(:post_reviews, updated)
    end
  end
end
