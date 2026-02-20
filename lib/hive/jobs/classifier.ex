defmodule Hive.Jobs.Classifier do
  @moduledoc """
  Classifies jobs by type and complexity to enable intelligent model selection.
  
  Uses heuristics and keyword matching to determine:
  - Job type (planning, implementation, research, etc.)
  - Complexity level (simple, moderate, complex)
  
  This enables the system to assign the optimal model for each job.
  """

  alias Hive.Runtime.ModelSelector

  @doc """
  Classify a job and recommend a model.
  
  Returns a map with:
  - `:job_type` - The classified job type
  - `:complexity` - The complexity level
  - `:recommended_model` - The optimal model for this job
  - `:reason` - Explanation for the classification
  """
  @spec classify_and_recommend(String.t(), String.t() | nil) :: map()
  def classify_and_recommend(title, description \\ nil) do
    text = "#{title} #{description || ""}" |> String.downcase()

    job_type = classify_type(text)
    complexity = classify_complexity(text, job_type)
    model = ModelSelector.select_model_for_job(job_type, complexity)

    %{
      job_type: job_type,
      complexity: complexity,
      recommended_model: model,
      reason: build_reason(job_type, complexity, text)
    }
  end

  @doc """
  Classify job type based on title and description.
  """
  def classify_type(text) do
    cond do
      matches_keywords?(text, ["plan", "design", "architect", "strategy", "approach"]) ->
        :planning

      matches_keywords?(text, ["research", "analyze", "investigate", "explore", "understand"]) ->
        :research

      matches_keywords?(text, ["summarize", "compress", "condense", "brief"]) ->
        :summarization

      matches_keywords?(text, ["fix", "bug", "issue", "problem", "resolve"]) ->
        :simple_fix

      matches_keywords?(text, ["verify", "validate", "check", "test", "confirm"]) ->
        :verification

      matches_keywords?(text, ["refactor", "restructure", "reorganize", "clean up"]) ->
        :refactoring

      matches_keywords?(text, ["implement", "create", "build", "add", "develop", "write"]) ->
        :implementation

      true ->
        :implementation
    end
  end

  @doc """
  Classify complexity based on text and job type.
  """
  def classify_complexity(text, job_type) do
    # Planning is always complex
    if job_type == :planning do
      :complex
    else
      cond do
        matches_keywords?(text, [
          "complex",
          "large",
          "multiple",
          "system",
          "architecture",
          "integration"
        ]) ->
          :complex

        matches_keywords?(text, ["simple", "small", "minor", "quick", "trivial"]) ->
          :simple

        true ->
          :moderate
      end
    end
  end

  # Private helpers

  defp matches_keywords?(text, keywords) do
    Enum.any?(keywords, fn keyword ->
      String.contains?(text, keyword)
    end)
  end

  defp build_reason(job_type, complexity, text) do
    type_reason = type_reason(job_type, text)
    complexity_reason = complexity_reason(complexity, text)

    "#{type_reason}. #{complexity_reason}"
  end

  defp type_reason(:planning, _text), do: "Classified as planning task"
  defp type_reason(:research, _text), do: "Classified as research/analysis task"
  defp type_reason(:summarization, _text), do: "Classified as summarization task"
  defp type_reason(:verification, _text), do: "Classified as verification task"
  defp type_reason(:refactoring, _text), do: "Classified as refactoring task"
  defp type_reason(:simple_fix, _text), do: "Classified as bug fix"
  defp type_reason(:implementation, _text), do: "Classified as implementation task"

  defp complexity_reason(:complex, _text), do: "High complexity detected"
  defp complexity_reason(:moderate, _text), do: "Moderate complexity"
  defp complexity_reason(:simple, _text), do: "Low complexity"
end
