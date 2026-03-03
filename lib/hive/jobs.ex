defmodule Hive.Jobs do
  @moduledoc """
  Context module for job lifecycle management.

  A job is a unit of work assigned to a bee within a quest. This module
  enforces valid status transitions -- the state machine that governs how
  a job moves from pending through to done or failed.

  Status transitions:

      pending --> assigned --> running --> done
                                     \\--> failed
      pending --> blocked --> pending (unblock)
      running --> blocked

  This is a pure context module: no process state, just data transformations
  against the store.
  """

  alias Hive.Store

  # -- Valid transitions -------------------------------------------------------

  @transitions %{
    {"pending", :assign} => "assigned",
    {"assigned", :start} => "running",
    {"running", :complete} => "done",
    {"running", :fail} => "failed",
    {"failed", :reset} => "pending",
    {"failed", :revive} => "running",
    {"pending", :block} => "blocked",
    {"running", :block} => "blocked",
    {"blocked", :unblock} => "pending"
  }

  # -- Public API --------------------------------------------------------------

  @doc """
  Creates a new job.

  Required attrs: `title`, `quest_id`, `comb_id`.
  Optional: `description`, `status`, `bee_id`.

  Returns `{:ok, job}` or `{:error, reason}`.
  """
  @spec create(map()) :: {:ok, map()} | {:error, term()}
  def create(attrs) do
    with :ok <- validate_required(attrs, [:title, :quest_id, :comb_id]) do
      # Auto-classify and recommend model if not provided
      classification =
        if attrs[:job_type] && attrs[:recommended_model] do
          %{
            job_type: attrs[:job_type],
            complexity: attrs[:complexity] || "moderate",
            recommended_model: attrs[:recommended_model],
            reason: attrs[:model_selection_reason]
          }
        else
          Hive.Jobs.Classifier.classify_and_recommend(
            attrs[:title] || attrs["title"],
            attrs[:description] || attrs["description"]
          )
        end

      record = %{
        title: attrs[:title] || attrs["title"],
        description: attrs[:description] || attrs["description"],
        status: attrs[:status] || attrs["status"] || "pending",
        quest_id: attrs[:quest_id] || attrs["quest_id"],
        comb_id: attrs[:comb_id] || attrs["comb_id"],
        bee_id: attrs[:bee_id] || attrs["bee_id"],
        council_id: attrs[:council_id],
        council_wave: attrs[:council_wave],
        council_experts: attrs[:council_experts],
        review_of_job_id: attrs[:review_of_job_id],
        # Multi-model support fields
        job_type: classification.job_type,
        complexity: classification.complexity,
        recommended_model: classification.recommended_model,
        assigned_model: attrs[:assigned_model] || classification.recommended_model,
        model_selection_reason: classification[:reason],
        verification_criteria: attrs[:verification_criteria] || [],
        estimated_context_tokens: attrs[:estimated_context_tokens],
        # Phase job fields
        phase_job: attrs[:phase_job] || false,
        phase: attrs[:phase],
        acceptance_criteria: attrs[:acceptance_criteria] || [],
        target_files: attrs[:target_files] || [],
        # Verification fields
        verification_status: "pending",
        verification_result: nil,
        verified_at: nil,
        # Risk level for adaptive permissions
        risk_level: classification[:risk_level] || attrs[:risk_level] || :low,
        # Retry tracking (persisted, survives Queen restarts)
        retry_count: attrs[:retry_count] || 0
      }

      Store.insert(:jobs, record)
    end
  end

  @doc """
  Assigns a job to a bee.

  Transitions: pending -> assigned.
  """
  @spec assign(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def assign(job_id, bee_id) do
    with {:ok, job} <- get(job_id),
         {:ok, next_status} <- validate_transition(job.status, :assign) do
      updated = %{job | status: next_status, bee_id: bee_id}
      Store.put(:jobs, updated)
    end
  end

  @doc "Starts a job. Transitions: assigned -> running."
  @spec start(String.t()) :: {:ok, map()} | {:error, atom()}
  def start(job_id), do: transition(job_id, :start)

  @doc "Completes a job. Transitions: running -> done."
  @spec complete(String.t()) :: {:ok, map()} | {:error, atom()}
  def complete(job_id), do: transition(job_id, :complete)

  @doc "Fails a job. Transitions: running -> failed."
  @spec fail(String.t()) :: {:ok, map()} | {:error, atom()}
  def fail(job_id), do: transition(job_id, :fail)

  @doc "Blocks a job. Transitions: pending | running -> blocked."
  @spec block(String.t()) :: {:ok, map()} | {:error, atom()}
  def block(job_id), do: transition(job_id, :block)

  @doc "Unblocks a job. Transitions: blocked -> pending."
  @spec unblock(String.t()) :: {:ok, map()} | {:error, atom()}
  def unblock(job_id), do: transition(job_id, :unblock)

  @doc """
  Resets a failed job back to pending so it can be retried.

  Transitions: failed -> pending. Also stops the assigned bee,
  cleans up its cell/worktree, and clears the bee_id assignment
  so the job can be assigned to a fresh bee.
  
  Optionally appends feedback to the job description.
  """
  @spec reset(String.t(), String.t() | nil) :: {:ok, map()} | {:error, atom()}
  def reset(job_id, feedback \\ nil) do
    with {:ok, job} <- get(job_id),
         {:ok, next_status} <- validate_transition(job.status, :reset) do
      cleanup_bee_and_cell(job.bee_id)
      
      new_description = 
        if feedback do
          (job.description || "") <> "\n\n## Feedback from previous attempt:\n\n" <> feedback
        else
          job.description
        end

      retry_count = Map.get(job, :retry_count, 0) + 1
      updated = %{job | status: next_status, bee_id: nil, retry_count: retry_count, description: new_description}
      Store.put(:jobs, updated)
    end
  end

  @doc """
  Revives a failed job by assigning it to a new bee.

  Transitions: failed -> running. Unlike `reset`, this does NOT clean up
  the old cell/worktree — the new bee reuses the existing worktree.
  """
  @spec revive(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def revive(job_id, bee_id) do
    with {:ok, job} <- get(job_id),
         {:ok, next_status} <- validate_transition(job.status, :revive) do
      updated = %{job | status: next_status, bee_id: bee_id}
      Store.put(:jobs, updated)
    end
  end

  defp cleanup_bee_and_cell(nil), do: :ok

  defp cleanup_bee_and_cell(bee_id) do
    # Stop the bee worker process if running
    Hive.Bees.stop(bee_id)

    # Find and remove the bee's active cell (worktree + branch)
    case Store.find_one(:cells, fn c -> c.bee_id == bee_id and c.status == "active" end) do
      nil -> :ok
      cell -> Hive.Cell.remove(cell.id, force: true)
    end

    # Mark bee as stopped
    case Hive.Bees.get(bee_id) do
      {:ok, bee} -> Store.put(:bees, %{bee | status: "stopped"})
      _ -> :ok
    end

    :ok
  end

  @doc """
  Lists jobs with optional filters.

  ## Options

    * `:quest_id` - filter by quest
    * `:status` - filter by status
    * `:bee_id` - filter by assigned bee
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    jobs = Store.all(:jobs)

    jobs =
      case Keyword.get(opts, :quest_id) do
        nil -> jobs
        v -> Enum.filter(jobs, &(Map.get(&1, :quest_id) == v))
      end

    jobs =
      case Keyword.get(opts, :status) do
        nil -> jobs
        v -> Enum.filter(jobs, &(Map.get(&1, :status) == v))
      end

    jobs =
      case Keyword.get(opts, :bee_id) do
        nil -> jobs
        v -> Enum.filter(jobs, &(Map.get(&1, :bee_id) == v))
      end

    Enum.sort_by(jobs, & &1.inserted_at, {:desc, DateTime})
  end

  @doc """
  Gets a job by ID.

  Returns `{:ok, job}` or `{:error, :not_found}`.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(job_id) do
    Store.fetch(:jobs, job_id)
  end

  # -- Private helpers ---------------------------------------------------------

  defp transition(job_id, action) do
    with {:ok, job} <- get(job_id),
         {:ok, next_status} <- validate_transition(job.status, action) do
      updated = %{job | status: next_status}
      result = Store.put(:jobs, updated)

      case action do
        :start ->
          Hive.Telemetry.emit([:hive, :job, :started], %{}, %{
            job_id: job_id,
            quest_id: job.quest_id
          })

        :complete ->
          Hive.Telemetry.emit([:hive, :job, :completed], %{}, %{
            job_id: job_id,
            quest_id: job.quest_id
          })

        _ ->
          :ok
      end

      result
    end
  end

  defp validate_transition(current_status, action) do
    case Map.get(@transitions, {current_status, action}) do
      nil -> {:error, :invalid_transition}
      next -> {:ok, next}
    end
  end

  defp validate_required(attrs, keys) do
    missing =
      Enum.filter(keys, fn key ->
        val = attrs[key] || attrs[Atom.to_string(key)]
        is_nil(val) or val == ""
      end)

    if missing == [], do: :ok, else: {:error, {:missing_fields, missing}}
  end

  # -- Dependency management ---------------------------------------------------

  @doc """
  Adds a dependency: `job_id` depends on `depends_on_id`.

  Validates no self-dependency and no cycles (BFS).
  Returns `{:ok, dep}` or `{:error, reason}`.
  """
  @spec add_dependency(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def add_dependency(job_id, depends_on_id) do
    cond do
      job_id == depends_on_id ->
        {:error, :self_dependency}

      has_cycle?(job_id, depends_on_id) ->
        {:error, :cycle_detected}

      true ->
        record = %{job_id: job_id, depends_on_id: depends_on_id}
        Store.insert(:job_dependencies, record)
    end
  end

  @doc "Removes a dependency between two jobs."
  @spec remove_dependency(String.t(), String.t()) :: :ok | {:error, :not_found}
  def remove_dependency(job_id, depends_on_id) do
    case Store.find_one(:job_dependencies, fn d ->
           d.job_id == job_id and d.depends_on_id == depends_on_id
         end) do
      nil ->
        {:error, :not_found}

      dep ->
        Store.delete(:job_dependencies, dep.id)
        :ok
    end
  end

  @doc "Lists jobs that `job_id` depends on."
  @spec dependencies(String.t()) :: [map()]
  def dependencies(job_id) do
    dep_ids =
      Store.filter(:job_dependencies, fn d -> d.job_id == job_id end)
      |> Enum.map(& &1.depends_on_id)

    Enum.flat_map(dep_ids, fn id ->
      case Store.get(:jobs, id) do
        nil -> []
        job -> [job]
      end
    end)
  end

  @doc "Lists jobs that depend on `job_id`."
  @spec dependents(String.t()) :: [map()]
  def dependents(job_id) do
    dep_job_ids =
      Store.filter(:job_dependencies, fn d -> d.depends_on_id == job_id end)
      |> Enum.map(& &1.job_id)

    Enum.flat_map(dep_job_ids, fn id ->
      case Store.get(:jobs, id) do
        nil -> []
        job -> [job]
      end
    end)
  end

  @doc "Returns true if all dependencies of `job_id` are done."
  @spec ready?(String.t()) :: boolean()
  def ready?(job_id) do
    deps = Store.filter(:job_dependencies, fn d -> d.job_id == job_id end)

    Enum.all?(deps, fn dep ->
      case Store.get(:jobs, dep.depends_on_id) do
        nil -> true
        job -> job.status == "done"
      end
    end)
  end

  @doc """
  After a job completes, transitions blocked dependents to pending
  if all their dependencies are now done.
  """
  @spec unblock_dependents(String.t()) :: :ok
  def unblock_dependents(job_id) do
    dependent_ids =
      Store.filter(:job_dependencies, fn d -> d.depends_on_id == job_id end)
      |> Enum.map(& &1.job_id)

    Enum.each(dependent_ids, fn dep_job_id ->
      if ready?(dep_job_id) do
        case get(dep_job_id) do
          {:ok, %{status: "blocked"}} -> unblock(dep_job_id)
          _ -> :ok
        end
      end
    end)

    :ok
  end

  # -- Private helpers ---------------------------------------------------------

  # BFS cycle detection: adding depends_on_id as a dependency of job_id
  # would create a cycle if job_id is reachable from depends_on_id.
  defp has_cycle?(job_id, depends_on_id) do
    bfs_reachable?(depends_on_id, job_id, MapSet.new())
  end

  defp bfs_reachable?(from_id, target_id, visited) do
    if from_id == target_id do
      true
    else
      if MapSet.member?(visited, from_id) do
        false
      else
        visited = MapSet.put(visited, from_id)

        deps =
          Store.filter(:job_dependencies, fn d -> d.job_id == from_id end)
          |> Enum.map(& &1.depends_on_id)

        Enum.any?(deps, fn dep_id -> bfs_reachable?(dep_id, target_id, visited) end)
      end
    end
  end
end
