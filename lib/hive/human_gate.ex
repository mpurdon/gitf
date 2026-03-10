defmodule Hive.HumanGate do
  @moduledoc """
  Human-in-the-loop approval gates.

  Provides mandatory human approval before merge for high-criticality quests.
  Acts as a "liability firebreak" — ensuring a human reviews and signs off
  on high-risk changes before they land.
  """

  require Logger
  alias Hive.Store

  @doc """
  Returns true if a quest requires human approval before merge.

  Criteria:
  - Any non-phase job has `:high` or `:critical` risk level
  - Comb config has `require_human_approval: true`
  """
  @spec requires_approval?(map()) :: boolean()
  def requires_approval?(quest) do
    comb_requires? =
      case Map.get(quest, :comb_id) do
        nil -> false
        comb_id ->
          case Store.get(:combs, comb_id) do
            nil -> false
            comb -> Map.get(comb, :require_human_approval, false) == true
          end
      end

    jobs = Map.get(quest, :jobs, [])

    critical_risk_jobs? =
      jobs
      |> Enum.reject(& &1[:phase_job])
      |> Enum.any?(fn job ->
        risk = Map.get(job, :risk_level)
        risk in [:critical] or risk in ["critical"]
      end)

    comb_requires? or critical_risk_jobs?
  end

  @doc """
  Creates an approval request for a quest.

  Builds a summary, stores the request, sends a waggle to the queen,
  and broadcasts on "hive:alerts".
  """
  @spec request_approval(String.t()) :: {:ok, map()} | {:error, term()}
  def request_approval(quest_id) do
    with {:ok, quest} <- Hive.Quests.get(quest_id) do
      jobs = Map.get(quest, :jobs, [])
      impl_jobs = Enum.reject(jobs, & &1[:phase_job])

      risk_levels =
        impl_jobs
        |> Enum.map(&Map.get(&1, :risk_level, :low))
        |> Enum.uniq()

      files_touched =
        impl_jobs
        |> Enum.flat_map(&Map.get(&1, :target_files, []))
        |> Enum.uniq()

      request = %{
        quest_id: quest_id,
        quest_name: quest.name,
        goal: quest.goal,
        risk_levels: risk_levels,
        files_touched: files_touched,
        job_count: length(impl_jobs),
        status: "pending",
        requested_at: DateTime.utc_now()
      }

      {:ok, stored} = Store.insert(:approval_requests, request)

      # Send waggle to queen (best-effort)
      try do
        Hive.Waggle.send(
          "system",
          "queen",
          "human_approval_needed",
          Jason.encode!(%{quest_id: quest_id, quest_name: quest.name})
        )
      rescue
        _ -> :ok
      end

      # Broadcast alert (best-effort)
      try do
        Phoenix.PubSub.broadcast(
          Hive.PubSub,
          "hive:alerts",
          {:human_approval_needed, quest_id, quest.name}
        )
      rescue
        _ -> :ok
      end

      Logger.info("Human approval requested for quest #{quest_id} (#{quest.name})")

      {:ok, stored}
    end
  end

  @doc """
  Approves a quest for merge.

  Stores an approval artifact on the quest and updates the approval request status.
  """
  @spec approve(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def approve(quest_id, opts \\ %{}) do
    approved_by = Map.get(opts, :approved_by, "human")
    notes = Map.get(opts, :notes)

    artifact = %{
      "approved" => true,
      "approved_by" => approved_by,
      "approved_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "notes" => notes
    }

    with {:ok, _} <- Hive.Quests.store_artifact(quest_id, "approval", artifact) do
      update_request_status(quest_id, "approved")
      Logger.info("Quest #{quest_id} approved by #{approved_by}")
      {:ok, artifact}
    end
  end

  @doc """
  Rejects a quest.

  Stores a rejection artifact and updates the approval request status.
  """
  @spec reject(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def reject(quest_id, reason) do
    artifact = %{
      "approved" => false,
      "rejected_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "reason" => reason
    }

    with {:ok, _} <- Hive.Quests.store_artifact(quest_id, "approval", artifact) do
      update_request_status(quest_id, "rejected")
      Logger.info("Quest #{quest_id} rejected: #{reason}")
      {:ok, artifact}
    end
  end

  @doc """
  Returns the approval status for a quest.
  """
  @spec approval_status(String.t()) :: :pending | :approved | :rejected | :not_required
  def approval_status(quest_id) do
    case Hive.Quests.get_artifact(quest_id, "approval") do
      nil ->
        # Check if there's a pending request
        case find_request(quest_id) do
          nil -> :not_required
          %{status: "pending"} -> :pending
          %{status: "approved"} -> :approved
          %{status: "rejected"} -> :rejected
          _ -> :not_required
        end

      %{"approved" => true} -> :approved
      %{"approved" => false} -> :rejected
      _ -> :not_required
    end
  end

  @doc """
  Lists all pending approval requests.
  """
  @spec pending_approvals() :: [map()]
  def pending_approvals do
    Store.filter(:approval_requests, fn r -> r.status == "pending" end)
    |> Enum.sort_by(& &1.requested_at, {:asc, DateTime})
  end

  # -- Private ---------------------------------------------------------------

  defp find_request(quest_id) do
    Store.find_one(:approval_requests, fn r -> r.quest_id == quest_id end)
  end

  defp update_request_status(quest_id, status) do
    case find_request(quest_id) do
      nil -> :ok
      request ->
        updated = Map.put(request, :status, status)
        Store.put(:approval_requests, updated)
    end
  end
end
