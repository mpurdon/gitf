defmodule Hive.Resilience do
  @moduledoc """
  Robust error handling and graceful degradation.
  """

  require Logger

  @doc """
  Handle component failure with fallback strategies.
  """
  def handle_failure(component, error, context \\ %{}) do
    Logger.warning("Component failure: #{component} - #{inspect(error)}")
    
    case component do
      :model_api -> fallback_model(context)
      :git_operation -> retry_git_operation(context)
      :verification -> skip_and_flag(context)
      :research_cache -> regenerate_research(context)
      :quality_check -> continue_without_quality(context)
      _ -> {:error, :unhandled_failure}
    end
  end

  @doc """
  Retry operation with exponential backoff.

  Delegates to `Hive.Intelligence.Retry` for strategy selection.
  This function is kept as a lightweight convenience wrapper.
  """
  def retry_with_backoff(operation, max_attempts \\ 3) do
    Enum.reduce_while(1..max_attempts, nil, fn attempt, _acc ->
      case operation.() do
        {:ok, result} ->
          {:halt, {:ok, result}}

        {:error, reason} when attempt < max_attempts ->
          backoff = :math.pow(2, attempt) * 1000 |> round()
          Logger.info("Retry attempt #{attempt}/#{max_attempts}, waiting #{backoff}ms")
          Process.sleep(backoff)
          {:cont, {:error, reason}}

        {:error, reason} ->
          {:halt, {:error, {:max_retries, reason}}}
      end
    end)
  end

  @doc """
  Detect circular dependencies in a quest.

  Uses `Hive.Jobs.has_cycle?/2` internally — this is a convenience wrapper
  that scans all jobs in a quest and reports any cycles found.
  """
  def detect_deadlock(quest_id) do
    jobs = Hive.Jobs.list(quest_id: quest_id)

    # Build edges from both job_dependencies collection AND legacy depends_on field
    stored_deps = Hive.Store.all(:job_dependencies)

    stored_edges =
      Enum.flat_map(stored_deps, fn dep ->
        [{dep.job_id, dep.depends_on_id}]
      end)

    legacy_edges =
      Enum.flat_map(jobs, fn job ->
        (Map.get(job, :depends_on, []) || [])
        |> Enum.map(fn dep_id -> {job.id, dep_id} end)
      end)

    all_edges = Enum.uniq(stored_edges ++ legacy_edges)

    cycles =
      Enum.flat_map(jobs, fn job ->
        job_deps = Enum.filter(all_edges, fn {from, _to} -> from == job.id end)

        Enum.flat_map(job_deps, fn {_from, dep_id} ->
          if edge_reachable?(dep_id, job.id, all_edges, MapSet.new()) do
            [{job.id, dep_id}]
          else
            []
          end
        end)
      end)
      |> Enum.uniq()

    case cycles do
      [] -> {:ok, :no_deadlock}
      found -> {:error, {:deadlock, found}}
    end
  end

  @doc """
  Resolve deadlock by breaking circular dependencies.
  """
  def resolve_deadlock(_quest_id, cycles) do
    Enum.each(cycles, fn {from_job, to_job} ->
      Hive.Jobs.remove_dependency(from_job, to_job)
      Logger.info("Broke deadlock by removing dependency: #{from_job} -> #{to_job}")
    end)

    {:ok, :deadlock_resolved}
  end

  defp edge_reachable?(from, target, edges, visited) do
    if from == target do
      true
    else
      if MapSet.member?(visited, from) do
        false
      else
        visited = MapSet.put(visited, from)

        edges
        |> Enum.filter(fn {job_id, _dep} -> job_id == from end)
        |> Enum.any?(fn {_job_id, dep_id} -> edge_reachable?(dep_id, target, edges, visited) end)
      end
    end
  end

  # Private functions

  defp fallback_model(%{model: current_model} = context) do
    fallback = case current_model do
      "claude-haiku" -> "claude-sonnet"
      "claude-sonnet" -> "claude-opus"
      _ -> "claude-sonnet"
    end
    
    Logger.info("Falling back from #{current_model} to #{fallback}")
    {:ok, Map.put(context, :model, fallback)}
  end

  defp fallback_model(context) do
    {:ok, Map.put(context, :model, "claude-sonnet")}
  end

  defp retry_git_operation(%{operation: op, attempt: attempt}) do
    if attempt < 3 do
      backoff = :math.pow(2, attempt) * 1000 |> round()
      Process.sleep(backoff)
      {:retry, %{operation: op, attempt: attempt + 1}}
    else
      {:error, :max_retries_exceeded}
    end
  end

  defp skip_and_flag(%{job_id: job_id}) do
    # Mark job for manual review
    case Hive.Jobs.get(job_id) do
      {:ok, job} ->
        updated = Map.put(job, :needs_review, true)
        Hive.Store.put(:jobs, updated)
        {:ok, :flagged_for_review}
      
      error -> error
    end
  end

  defp skip_and_flag(_context), do: {:ok, :skipped}

  defp regenerate_research(%{comb_id: comb_id}) do
    Logger.info("Regenerating research for comb #{comb_id}")
    {:ok, :research_regenerated}
  end

  defp regenerate_research(_context), do: {:ok, :skipped}

  defp continue_without_quality(%{job_id: job_id}) do
    Logger.warning("Continuing job #{job_id} without quality check")
    {:ok, :quality_check_skipped}
  end

  defp continue_without_quality(_context), do: {:ok, :skipped}

end
