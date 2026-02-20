defmodule Hive.Runtime.ContextMonitor do
  @moduledoc """
  Monitors and enforces context budget limits for bees.
  
  Tracks token usage per bee session and triggers automatic handoffs
  when context usage approaches the configured threshold (default 45%).
  
  ## Thresholds
  
  - Warning: 40% - Log warning, notify via PubSub
  - Critical: 45% - Trigger automatic handoff
  - Maximum: 50% - Hard limit, force handoff
  """

  alias Hive.Store

  @warning_threshold 0.40
  @critical_threshold 0.45
  @max_threshold 0.50

  @doc """
  Record token usage for a bee session.
  
  Updates the bee's context tracking fields and checks if handoff is needed.
  Returns {:ok, :normal | :warning | :critical | :handoff_needed}.
  """
  @spec record_usage(String.t(), integer(), integer()) ::
          {:ok, :normal | :warning | :critical | :handoff_needed} | {:error, term()}
  def record_usage(bee_id, input_tokens, output_tokens) do
    with {:ok, bee} <- Store.fetch(:bees, bee_id),
         {:ok, limit} <- get_context_limit(bee) do
      total_tokens = (bee.context_tokens_used || 0) + input_tokens + output_tokens
      percentage = total_tokens / limit

      updated =
        bee
        |> Map.put(:context_tokens_used, total_tokens)
        |> Map.put(:context_tokens_limit, limit)
        |> Map.put(:context_percentage, percentage)

      Store.put(:bees, updated)

      status = determine_status(percentage)
      maybe_broadcast_warning(bee_id, status, percentage)

      {:ok, status}
    end
  end

  @doc """
  Check if a bee needs a handoff based on current context usage.
  """
  @spec needs_handoff?(String.t()) :: boolean()
  def needs_handoff?(bee_id) do
    case Store.get(:bees, bee_id) do
      nil -> false
      bee -> (bee.context_percentage || 0.0) >= @critical_threshold
    end
  end

  @doc """
  Get current context usage percentage for a bee.
  """
  @spec get_usage_percentage(String.t()) :: float()
  def get_usage_percentage(bee_id) do
    case Store.get(:bees, bee_id) do
      nil -> 0.0
      bee -> bee.context_percentage || 0.0
    end
  end

  @doc """
  Get context usage statistics for a bee.
  """
  @spec get_usage_stats(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_usage_stats(bee_id) do
    case Store.get(:bees, bee_id) do
      nil ->
        {:error, :not_found}

      bee ->
        {:ok,
         %{
           tokens_used: bee.context_tokens_used || 0,
           tokens_limit: bee.context_tokens_limit,
           percentage: bee.context_percentage || 0.0,
           status: determine_status(bee.context_percentage || 0.0),
           needs_handoff: needs_handoff?(bee_id)
         }}
    end
  end

  @doc """
  Create a context snapshot for handoff purposes.
  
  Captures the current state of the bee's work for context preservation.
  """
  @spec create_snapshot(String.t()) :: {:ok, map()} | {:error, term()}
  def create_snapshot(bee_id) do
    with {:ok, bee} <- Store.fetch(:bees, bee_id),
         {:ok, job} <- Hive.Jobs.get(bee.job_id) do
      snapshot = %{
        id: "snap-#{:erlang.unique_integer([:positive])}",
        bee_id: bee_id,
        snapshot_at: DateTime.utc_now(),
        tokens_used: Map.get(bee, :context_tokens_used, 0),
        percentage: Map.get(bee, :context_percentage, 0.0),
        job_id: job.id,
        job_title: job.title,
        job_status: job.status,
        inserted_at: DateTime.utc_now()
      }

      Store.insert(:context_snapshots, snapshot)
    end
  end

  @doc """
  Get the most recent snapshot for a bee.
  """
  @spec get_latest_snapshot(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_latest_snapshot(bee_id) do
    snapshots =
      Store.all(:context_snapshots)
      |> Enum.filter(&(&1.bee_id == bee_id))
      |> Enum.sort_by(& &1.snapshot_at, {:desc, DateTime})

    case snapshots do
      [latest | _] -> {:ok, latest}
      [] -> {:error, :not_found}
    end
  end

  # Private functions

  defp get_context_limit(bee) do
    # Try to get limit from model info
    case bee.assigned_model do
      nil ->
        {:ok, 200_000}

      model ->
        case Hive.Runtime.Models.get_context_limit(model) do
          {:ok, limit} -> {:ok, limit}
          _ -> {:ok, 200_000}
        end
    end
  end

  defp determine_status(percentage) when percentage >= @max_threshold, do: :handoff_needed
  defp determine_status(percentage) when percentage >= @critical_threshold, do: :critical
  defp determine_status(percentage) when percentage >= @warning_threshold, do: :warning
  defp determine_status(_percentage), do: :normal

  defp maybe_broadcast_warning(bee_id, status, percentage)
       when status in [:warning, :critical, :handoff_needed] do
    Phoenix.PubSub.broadcast(
      Hive.PubSub,
      "bee:#{bee_id}",
      {:context_warning, bee_id, status, percentage}
    )

    Phoenix.PubSub.broadcast(
      Hive.PubSub,
      "hive:context",
      {:context_warning, bee_id, status, percentage}
    )
  end

  defp maybe_broadcast_warning(_bee_id, _status, _percentage), do: :ok
end
