defmodule GiTF.Runtime.ContextMonitor do
  @moduledoc """
  Monitors and enforces context budget limits for ghosts.
  
  Tracks token usage per ghost session and triggers automatic handoffs
  when context usage approaches the configured threshold (default 45%).
  
  ## Thresholds
  
  - Warning: 40% - Log warning, notify via PubSub
  - Critical: 45% - Trigger automatic handoff
  - Maximum: 50% - Hard limit, force handoff
  """

  alias GiTF.Store

  @warning_threshold 0.40
  @critical_threshold 0.45
  @max_threshold 0.50

  @doc """
  Record token usage for a ghost session.
  
  Updates the ghost's context tracking fields and checks if handoff is needed.
  Returns {:ok, :normal | :warning | :critical | :handoff_needed}.
  """
  @spec record_usage(String.t(), integer(), integer()) ::
          {:ok, :normal | :warning | :critical | :handoff_needed} | {:error, term()}
  def record_usage(ghost_id, input_tokens, output_tokens) do
    with {:ok, ghost} <- Store.fetch(:ghosts, ghost_id),
         {:ok, limit} <- get_context_limit(ghost) do
      total_tokens = (ghost.context_tokens_used || 0) + input_tokens + output_tokens
      percentage = total_tokens / limit

      updated =
        ghost
        |> Map.put(:context_tokens_used, total_tokens)
        |> Map.put(:context_tokens_limit, limit)
        |> Map.put(:context_percentage, percentage)

      Store.put(:ghosts, updated)

      status = determine_status(percentage)
      maybe_broadcast_warning(ghost_id, status, percentage)

      {:ok, status}
    end
  end

  @doc """
  Check if a ghost needs a handoff based on current context usage.
  """
  @spec needs_handoff?(String.t()) :: boolean()
  def needs_handoff?(ghost_id) do
    case Store.get(:ghosts, ghost_id) do
      nil -> false
      ghost -> (ghost.context_percentage || 0.0) >= @critical_threshold
    end
  end

  @doc """
  Get current context usage percentage for a ghost.
  """
  @spec get_usage_percentage(String.t()) :: float()
  def get_usage_percentage(ghost_id) do
    case Store.get(:ghosts, ghost_id) do
      nil -> 0.0
      ghost -> ghost.context_percentage || 0.0
    end
  end

  @doc """
  Get context usage statistics for a ghost.
  """
  @spec get_usage_stats(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_usage_stats(ghost_id) do
    case Store.get(:ghosts, ghost_id) do
      nil ->
        {:error, :not_found}

      ghost ->
        {:ok,
         %{
           tokens_used: ghost.context_tokens_used || 0,
           tokens_limit: ghost.context_tokens_limit,
           percentage: ghost.context_percentage || 0.0,
           status: determine_status(ghost.context_percentage || 0.0),
           needs_handoff: needs_handoff?(ghost_id)
         }}
    end
  end

  @doc """
  Create a context snapshot for handoff purposes.
  
  Captures the current state of the ghost's work for context preservation.
  """
  @spec create_snapshot(String.t()) :: {:ok, map()} | {:error, term()}
  def create_snapshot(ghost_id) do
    with {:ok, ghost} <- Store.fetch(:ghosts, ghost_id),
         {:ok, job} <- GiTF.Jobs.get(ghost.job_id) do
      snapshot = %{
        id: "snap-#{:erlang.unique_integer([:positive])}",
        ghost_id: ghost_id,
        snapshot_at: DateTime.utc_now(),
        tokens_used: Map.get(ghost, :context_tokens_used, 0),
        percentage: Map.get(ghost, :context_percentage, 0.0),
        job_id: job.id,
        job_title: job.title,
        job_status: job.status,
        inserted_at: DateTime.utc_now()
      }

      Store.insert(:context_snapshots, snapshot)
    end
  end

  @doc """
  Get the most recent snapshot for a ghost.
  """
  @spec get_latest_snapshot(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_latest_snapshot(ghost_id) do
    snapshots =
      Store.all(:context_snapshots)
      |> Enum.filter(&(&1.ghost_id == ghost_id))
      |> Enum.sort_by(& &1.snapshot_at, {:desc, DateTime})

    case snapshots do
      [latest | _] -> {:ok, latest}
      [] -> {:error, :not_found}
    end
  end

  # Private functions

  defp get_context_limit(ghost) do
    # Try to get limit from model info
    case ghost.assigned_model do
      nil ->
        {:ok, 200_000}

      model ->
        case GiTF.Runtime.Models.get_context_limit(model) do
          {:ok, limit} -> {:ok, limit}
          _ -> {:ok, 200_000}
        end
    end
  end

  defp determine_status(percentage) when percentage >= @max_threshold, do: :handoff_needed
  defp determine_status(percentage) when percentage >= @critical_threshold, do: :critical
  defp determine_status(percentage) when percentage >= @warning_threshold, do: :warning
  defp determine_status(_percentage), do: :normal

  defp maybe_broadcast_warning(ghost_id, status, percentage)
       when status in [:warning, :critical, :handoff_needed] do
    Phoenix.PubSub.broadcast(
      GiTF.PubSub,
      "ghost:#{ghost_id}",
      {:context_warning, ghost_id, status, percentage}
    )

    Phoenix.PubSub.broadcast(
      GiTF.PubSub,
      "section:context",
      {:context_warning, ghost_id, status, percentage}
    )
  end

  defp maybe_broadcast_warning(_ghost_id, _status, _percentage), do: :ok
end
