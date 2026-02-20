defmodule Hive.Council do
  @moduledoc """
  Context module for the Expert Council system.

  Councils are hive-wide collections of expert agents that can be applied
  to any quest as review waves. Each council contains 3-7 real-world expert
  profiles generated from model-assisted research.

  ## Lifecycle

      create(domain) → status: "generating" → discover experts → generate agents → status: "ready"
      apply_to_quest(council_id, quest_id) → create review wave jobs chained after implementation jobs
      install_experts(council_id, expert_keys, worktree_path) → copy agent files to worktree

  ## Storage

  Council records are stored in the `:councils` collection (prefix `cnl`).
  Agent files are stored hive-wide in `.hive/councils/<council-name>/`.
  """

  require Logger

  alias Hive.Store

  @agents_dir ".claude/agents"

  # -- Public API --------------------------------------------------------------

  @doc """
  Creates a new council by researching experts for a domain.

  Discovers experts via the active model provider, then generates an
  agent .md file for each expert. Returns `{:ok, council}` when complete.

  ## Options

    * `:experts` - number of experts to discover (default: 5)
  """
  @spec create(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(domain, opts \\ []) do
    name = slugify(domain)

    # Check for duplicate name
    case Store.find_one(:councils, fn c -> c.name == name end) do
      nil ->
        do_create(domain, name, opts)

      existing ->
        {:error, {:already_exists, existing.id}}
    end
  end

  @doc """
  Gets a council by ID.

  Returns `{:ok, council}` or `{:error, :not_found}`.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(id) do
    Store.fetch(:councils, id)
  end

  @doc """
  Lists all councils.

  ## Options

    * `:status` - filter by status ("generating", "ready", "failed")
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    councils = Store.all(:councils)

    councils =
      case Keyword.get(opts, :status) do
        nil -> councils
        status -> Enum.filter(councils, &(&1.status == status))
      end

    Enum.sort_by(councils, & &1.inserted_at, {:desc, DateTime})
  end

  @doc """
  Deletes a council and its agent files from disk.

  Returns `:ok` or `{:error, :not_found}`.
  """
  @spec delete(String.t()) :: :ok | {:error, :not_found}
  def delete(id) do
    case Store.get(:councils, id) do
      nil ->
        {:error, :not_found}

      council ->
        # Remove agent files from disk
        case council_dir(council.name) do
          {:ok, dir} -> File.rm_rf(dir)
          _ -> :ok
        end

        Store.delete(:councils, id)
    end
  end

  @doc """
  Dry-run: discovers experts for a domain without creating a council.

  Returns `{:ok, [expert]}` or `{:error, reason}`.
  """
  @spec preview(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def preview(domain, opts \\ []) do
    Hive.Council.Generator.discover_experts(domain, opts)
  end

  @doc """
  Applies a council to a quest by creating review wave jobs.

  For each implementation job in the quest, creates chained review wave
  jobs that partition the council's experts into waves.

  ## Options

    * `:wave_size` - number of experts per wave (default: 2)

  Returns `{:ok, %{wave_count: n, jobs_created: n}}` or `{:error, reason}`.
  """
  @spec apply_to_quest(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def apply_to_quest(council_id, quest_id, opts \\ []) do
    wave_size = Keyword.get(opts, :wave_size, 2)

    with {:ok, council} <- get(council_id),
         :ok <- validate_ready(council),
         {:ok, quest} <- Hive.Quests.get(quest_id) do
      # Tag the quest with the council
      quest_record = Store.get(:quests, quest_id)
      Store.put(:quests, Map.put(quest_record, :council_id, council_id))

      # Partition experts into waves
      waves = council.experts |> Enum.chunk_every(wave_size) |> Enum.with_index(1)

      # Get implementation jobs (non-review jobs)
      impl_jobs = Enum.reject(quest.jobs, fn j -> Map.get(j, :council_id) != nil end)

      if impl_jobs == [] do
        {:error, :no_implementation_jobs}
      else
        jobs_created =
          Enum.flat_map(impl_jobs, fn impl_job ->
            create_wave_chain(council, impl_job, waves, quest_id)
          end)

        wave_count = length(waves)

        Hive.Telemetry.emit([:hive, :council, :applied], %{}, %{
          council_id: council_id,
          quest_id: quest_id,
          wave_count: wave_count,
          expert_count: length(council.experts)
        })

        Logger.info(
          "Council #{council.name} applied to quest #{quest_id}: " <>
            "#{length(jobs_created)} review jobs in #{wave_count} waves"
        )

        {:ok, %{wave_count: wave_count, jobs_created: length(jobs_created)}}
      end
    end
  end

  @doc """
  Installs specific expert agent files into a worktree.

  Copies the named expert agent .md files from the council's hive-wide
  directory into the worktree's `.claude/agents/` directory.
  """
  @spec install_experts(String.t(), [String.t()], String.t()) :: :ok | {:error, term()}
  def install_experts(council_id, expert_keys, worktree_path) do
    with {:ok, council} <- get(council_id),
         {:ok, src_dir} <- council_dir(council.name) do
      dst_dir = Path.join(worktree_path, @agents_dir)
      File.mkdir_p!(dst_dir)

      Enum.each(expert_keys, fn key ->
        src = Path.join(src_dir, "#{key}-expert.md")
        dst = Path.join(dst_dir, "#{key}-expert.md")

        if File.exists?(src) do
          File.cp!(src, dst)
        end
      end)

      :ok
    end
  end

  # -- Private: creation -------------------------------------------------------

  defp do_create(domain, name, opts) do
    record = %{
      name: name,
      domain: domain,
      status: "generating",
      experts: [],
      tags: []
    }

    {:ok, council} = Store.insert(:councils, record)

    case do_generate(council, opts) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, reason} ->
        Store.put(:councils, %{council | status: "failed"})
        {:error, reason}
    end
  end

  defp do_generate(council, opts) do
    with {:ok, experts} <- Hive.Council.Generator.discover_experts(council.domain, opts),
         {:ok, dir} <- ensure_council_dir(council.name),
         :ok <- generate_all_agents(experts, council.domain, dir, opts) do
      updated = %{council | status: "ready", experts: experts}
      Store.put(:councils, updated)
    end
  end

  defp generate_all_agents(experts, domain, dir, opts) do
    Enum.each(experts, fn expert ->
      {:ok, content} = Hive.Council.Generator.generate_expert_agent(expert, domain, opts)
      path = Path.join(dir, "#{expert.key}-expert.md")
      File.write!(path, content)
      Logger.info("Generated expert agent: #{expert.key}-expert.md")
    end)

    :ok
  end

  # -- Private: wave creation --------------------------------------------------

  defp create_wave_chain(council, impl_job, waves, quest_id) do
    Enum.reduce(waves, {impl_job.id, []}, fn {wave_experts, wave_num}, {prev_job_id, acc} ->
      expert_names = Enum.map(wave_experts, & &1.name) |> Enum.join(", ")
      expert_keys = Enum.map(wave_experts, & &1.key)

      expert_details =
        Enum.map(wave_experts, fn e -> "#{e.name} (#{e.focus})" end) |> Enum.join(", ")

      title = "[Wave #{wave_num}: #{expert_names}] Review #{impl_job.title}"

      description = """
      ## Council Review: #{council.domain}
      **Wave:** #{wave_num} of #{length(waves)}
      **Experts:** #{expert_details}
      **Reviewing:** #{impl_job.id} — #{impl_job.title}

      Review the existing implementation through the lens of the above experts.
      Refine and improve — do not rewrite from scratch.
      The expert agent files installed in .claude/agents/ embody each expert's
      specific methodology. Follow their guidance.
      """

      attrs = %{
        title: title,
        description: description,
        quest_id: quest_id,
        comb_id: impl_job.comb_id,
        council_id: council.id,
        council_wave: wave_num,
        council_experts: expert_keys,
        review_of_job_id: impl_job.id
      }

      {:ok, review_job} = Hive.Jobs.create(attrs)

      # Chain: review job depends on previous job
      Hive.Jobs.add_dependency(review_job.id, prev_job_id)

      Hive.Telemetry.emit([:hive, :council, :wave_start], %{}, %{
        council_id: council.id,
        wave: wave_num,
        experts: expert_keys,
        job_id: review_job.id
      })

      {review_job.id, [review_job | acc]}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  # -- Private: helpers --------------------------------------------------------

  defp validate_ready(%{status: "ready"}), do: :ok
  defp validate_ready(%{status: status}), do: {:error, {:not_ready, status}}

  defp council_dir(name) do
    case Hive.hive_dir() do
      {:ok, root} -> {:ok, Path.join([root, ".hive", "councils", name])}
      error -> error
    end
  end

  defp ensure_council_dir(name) do
    case council_dir(name) do
      {:ok, dir} ->
        File.mkdir_p!(dir)
        {:ok, dir}

      error ->
        error
    end
  end

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.trim()
    |> String.replace(~r/\s+/, "-")
  end
end
