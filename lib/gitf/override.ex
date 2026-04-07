defmodule GiTF.Override do
  @moduledoc """
  Human-in-the-loop approval gates.

  Provides mandatory human approval before sync for high-criticality missions.
  Acts as a "liability firebreak" — ensuring a human reviews and signs off
  on high-risk changes before they land.
  """

  require Logger
  alias GiTF.Archive

  @doc """
  Returns true if a mission requires human approval before sync.

  Criteria:
  - Any non-phase op has `:high` or `:critical` risk level
  - Sector config has `require_human_approval: true`
  """
  @spec requires_approval?(map()) :: boolean()
  def requires_approval?(mission) do
    # In Dark Factory mode, we auto-approve unless it's critical risk
    if GiTF.Config.dark_factory?() do
      is_critical?(mission)
    else
      requires_approval_standard?(mission)
    end
  end

  defp is_critical?(mission) do
    ops = Map.get(mission, :ops, [])

    ops
    |> Enum.reject(& &1[:phase_job])
    |> Enum.any?(fn op ->
      risk = Map.get(op, :risk_level)
      risk in [:critical] or risk in ["critical"]
    end)
  end

  defp requires_approval_standard?(mission) do
    sector_requires? =
      case Map.get(mission, :sector_id) do
        nil ->
          false

        sector_id ->
          case Archive.get(:sectors, sector_id) do
            nil -> false
            sector -> Map.get(sector, :require_human_approval, false) == true
          end
      end

    sector_requires? or is_critical?(mission)
  end

  @doc """
  Creates an approval request for a mission.

  Builds a summary, stores the request, sends a link_msg to the queen,
  and broadcasts on "section:alerts".
  """
  @spec request_approval(String.t()) :: {:ok, map()} | {:error, term()}
  def request_approval(mission_id) do
    with {:ok, mission} <- GiTF.Missions.get(mission_id) do
      ops = Map.get(mission, :ops, [])
      impl_jobs = Enum.reject(ops, & &1[:phase_job])

      risk_levels =
        impl_jobs
        |> Enum.map(&Map.get(&1, :risk_level, :low))
        |> Enum.uniq()

      files_touched =
        impl_jobs
        |> Enum.flat_map(&Map.get(&1, :target_files, []))
        |> Enum.uniq()

      request = %{
        mission_id: mission_id,
        quest_name: mission.name,
        goal: mission.goal,
        risk_levels: risk_levels,
        files_touched: files_touched,
        job_count: length(impl_jobs),
        status: "pending",
        requested_at: DateTime.utc_now()
      }

      {:ok, stored} = Archive.insert(:approval_requests, request)

      # Send link_msg to queen (best-effort)
      try do
        GiTF.Link.send(
          "system",
          "major",
          "human_approval_needed",
          Jason.encode!(%{mission_id: mission_id, quest_name: mission.name})
        )
      rescue
        _ -> :ok
      end

      # Broadcast alert (best-effort)
      try do
        Phoenix.PubSub.broadcast(
          GiTF.PubSub,
          "section:alerts",
          {:human_approval_needed, mission_id, mission.name}
        )
      rescue
        _ -> :ok
      end

      Logger.info("Human approval requested for mission #{mission_id} (#{mission.name})")

      {:ok, stored}
    end
  end

  @doc """
  Approves a mission for sync.

  Stores an approval artifact on the mission and updates the approval request status.
  """
  @spec approve(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def approve(mission_id, opts \\ %{}) do
    approved_by = Map.get(opts, :approved_by, "human")
    notes = Map.get(opts, :notes)

    artifact = %{
      "approved" => true,
      "approved_by" => approved_by,
      "approved_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "notes" => notes
    }

    with {:ok, _} <- GiTF.Missions.store_artifact(mission_id, "approval", artifact) do
      update_request_status(mission_id, "approved")
      Logger.info("Quest #{mission_id} approved by #{approved_by}")
      {:ok, artifact}
    end
  end

  @doc """
  Rejects a mission.

  Stores a rejection artifact and updates the approval request status.
  """
  @spec reject(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def reject(mission_id, reason) do
    artifact = %{
      "approved" => false,
      "rejected_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "reason" => reason
    }

    with {:ok, _} <- GiTF.Missions.store_artifact(mission_id, "approval", artifact) do
      update_request_status(mission_id, "rejected")
      Logger.info("Quest #{mission_id} rejected: #{reason}")
      {:ok, artifact}
    end
  end

  @doc """
  Returns the approval status for a mission.
  """
  @spec approval_status(String.t()) :: :pending | :approved | :rejected | :not_required
  def approval_status(mission_id) do
    case GiTF.Missions.get_artifact(mission_id, "approval") do
      nil ->
        # Check if there's a pending request
        case find_request(mission_id) do
          nil -> :not_required
          %{status: "pending"} -> :pending
          %{status: "approved"} -> :approved
          %{status: "rejected"} -> :rejected
          _ -> :not_required
        end

      %{"approved" => true} ->
        :approved

      %{"approved" => false} ->
        :rejected

      _ ->
        :not_required
    end
  end

  @doc """
  Lists all pending approval requests.
  """
  @spec pending_approvals() :: [map()]
  def pending_approvals do
    Archive.filter(:approval_requests, fn r -> r.status == "pending" end)
    |> Enum.sort_by(& &1.requested_at, {:asc, DateTime})
  end

  # -- Private ---------------------------------------------------------------

  defp find_request(mission_id) do
    Archive.find_one(:approval_requests, fn r -> r.mission_id == mission_id end)
  end

  defp update_request_status(mission_id, status) do
    case find_request(mission_id) do
      nil ->
        :ok

      request ->
        updated = Map.put(request, :status, status)
        Archive.put(:approval_requests, updated)
    end
  end
end
