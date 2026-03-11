defmodule GiTF.Triage do
  @moduledoc """
  Categorizes jobs by complexity and determines what pipeline they need.

  Every job flows through triage before a ghost is spawned. The triage result
  determines whether the job needs scouting (read-only codebase analysis),
  drone verification, and which model tier to use.

  Complexity signals are checked in priority order -- the first match wins.
  """

  alias GiTF.Jobs

  @type complexity :: :simple | :moderate | :complex

  @type pipeline :: %{
          skip_drone: boolean(),
          skip_scout: boolean(),
          recommended_model: String.t()
        }

  @complex_keywords ~w(refactor redesign migration overhaul architecture)
  @simple_keywords ["fix typo", "update config", "bump version", "rename", "add comment"]

  # -- Public API --------------------------------------------------------------

  @doc """
  Triages a job map, returning `{complexity, pipeline}`.

  Checks complexity signals in priority order:
  1. Target file count (5+ files => complex)
  2. Dependencies (any => at least moderate)
  3. Architectural keywords in title/description => complex
  4. Simple keywords in title/description => simple
  5. Pre-set `complexity` field from classifier
  6. Default: moderate
  """
  @spec triage(map()) :: {complexity(), pipeline()}
  def triage(job) do
    complexity = determine_complexity(job)
    {complexity, pipeline_for(complexity)}
  end

  @doc """
  Returns the pipeline config for a given complexity atom.
  """
  @spec pipeline_for(complexity()) :: pipeline()
  def pipeline_for(:simple) do
    %{skip_drone: true, skip_scout: true, recommended_model: "haiku"}
  end

  def pipeline_for(:moderate) do
    %{skip_drone: false, skip_scout: true, recommended_model: "sonnet"}
  end

  def pipeline_for(:complex) do
    %{skip_drone: false, skip_scout: false, recommended_model: "opus"}
  end

  # -- Private: complexity determination ---------------------------------------

  defp determine_complexity(job) do
    cond do
      many_target_files?(job) -> :complex
      has_dependencies?(job) -> at_least_moderate(job)
      has_architectural_keywords?(job) -> :complex
      has_simple_keywords?(job) -> :simple
      true -> from_classifier(job)
    end
  end

  defp many_target_files?(job) do
    files = Map.get(job, :target_files, [])
    is_list(files) and length(files) >= 5
  end

  defp has_dependencies?(job) do
    job_id = Map.get(job, :id)
    job_id != nil and Jobs.dependencies(job_id) != []
  rescue
    _ -> false
  end

  defp at_least_moderate(job) do
    case from_classifier(job) do
      :simple -> :moderate
      other -> other
    end
  end

  defp has_architectural_keywords?(job) do
    text = job_text(job)
    Enum.any?(@complex_keywords, &String.contains?(text, &1))
  end

  defp has_simple_keywords?(job) do
    text = job_text(job)
    Enum.any?(@simple_keywords, &String.contains?(text, &1))
  end

  defp from_classifier(job) do
    case Map.get(job, :complexity) do
      c when c in ["trivial", "low"] -> :simple
      "moderate" -> :moderate
      c when c in ["high", "critical"] -> :complex
      _ -> :moderate
    end
  end

  defp job_text(job) do
    title = Map.get(job, :title, "") || ""
    description = Map.get(job, :description, "") || ""
    String.downcase(title <> " " <> description)
  end
end
