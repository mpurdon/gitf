defmodule GiTF.Ops.Classifier do
  @moduledoc """
  Classifies ops by type and complexity to enable intelligent model selection.

  Uses heuristics and keyword matching to determine:
  - Job type (planning, implementation, research, etc.)
  - Complexity level (simple, moderate, complex)

  This enables the system to assign the optimal model for each op.
  """

  alias GiTF.Runtime.ModelSelector

  @doc """
  Classify a op and recommend a model.

  Returns a map with:
  - `:op_type` - The classified op type
  - `:complexity` - The complexity level
  - `:recommended_model` - The optimal model for this op
  - `:reason` - Explanation for the classification
  """
  @spec classify_and_recommend(String.t(), String.t() | nil) :: map()
  def classify_and_recommend(title, description \\ nil) do
    text = "#{title} #{description || ""}" |> String.downcase()

    op_type = classify_type(text)
    complexity = classify_complexity(text, op_type)
    model = ModelSelector.select_model_for_job(op_type, complexity)
    risk_level = classify_risk(title, description)

    %{
      op_type: op_type,
      complexity: complexity,
      recommended_model: model,
      risk_level: risk_level,
      reason: build_reason(op_type, complexity, text)
    }
  end

  @doc """
  Classify op type based on title and description.
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
        :audit

      matches_keywords?(text, ["refactor", "restructure", "reorganize", "clean up"]) ->
        :refactoring

      matches_keywords?(text, ["implement", "create", "build", "add", "develop", "write"]) ->
        :implementation

      true ->
        :implementation
    end
  end

  @doc """
  Classify complexity based on text and op type.
  """
  def classify_complexity(text, op_type) do
    # Planning is always complex
    if op_type == :planning do
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

  @high_risk_keywords ~w(migration security auth deploy credential database secret password token)
  @high_risk_files [
    "**/config/**",
    "**/migrations/**",
    "**/auth/**",
    "Dockerfile",
    ".env",
    "**/secrets/**",
    "**/credentials/**"
  ]

  @doc """
  Classify risk level based on title, description, and target files.

  Returns `:low`, `:medium`, `:high`, or `:critical`.

  Risk signals:
  - Keywords: migration, security, auth, deploy, credential, etc.
  - File paths: config/, migrations/, auth/, Dockerfile, .env
  - Multiple high signals → critical
  """
  @spec classify_risk(String.t(), String.t() | nil, list() | nil) ::
          :low | :medium | :high | :critical
  def classify_risk(title, description \\ nil, target_files \\ nil) do
    text = "#{title} #{description || ""}" |> String.downcase()
    files = target_files || []

    keyword_hits = Enum.count(@high_risk_keywords, &String.contains?(text, &1))
    file_hits = count_risky_files(files)
    total_hits = keyword_hits + file_hits

    cond do
      total_hits >= 3 -> :critical
      total_hits == 2 -> :high
      total_hits == 1 -> :medium
      true -> :low
    end
  end

  defp count_risky_files(files) do
    Enum.count(files, fn file ->
      file_lower = String.downcase(file)

      Enum.any?(@high_risk_files, fn pattern ->
        cond do
          String.starts_with?(pattern, "**/") ->
            # Match directory anywhere in path
            dir = String.trim_leading(pattern, "**/") |> String.trim_trailing("/**")
            String.contains?(file_lower, "/#{dir}/") or String.starts_with?(file_lower, "#{dir}/")

          true ->
            # Exact filename match
            Path.basename(file_lower) == String.downcase(pattern) or
              file_lower == String.downcase(pattern)
        end
      end)
    end)
  end

  # Private helpers

  defp matches_keywords?(text, keywords) do
    Enum.any?(keywords, fn keyword ->
      String.contains?(text, keyword)
    end)
  end

  defp build_reason(op_type, complexity, text) do
    type_reason = type_reason(op_type, text)
    complexity_reason = complexity_reason(complexity, text)

    "#{type_reason}. #{complexity_reason}"
  end

  defp type_reason(:planning, _text), do: "Classified as planning task"
  defp type_reason(:research, _text), do: "Classified as research/analysis task"
  defp type_reason(:summarization, _text), do: "Classified as summarization task"
  defp type_reason(:audit, _text), do: "Classified as verification task"
  defp type_reason(:refactoring, _text), do: "Classified as refactoring task"
  defp type_reason(:simple_fix, _text), do: "Classified as bug fix"
  defp type_reason(:implementation, _text), do: "Classified as implementation task"

  defp complexity_reason(:complex, _text), do: "High complexity detected"
  defp complexity_reason(:moderate, _text), do: "Moderate complexity"
  defp complexity_reason(:simple, _text), do: "Low complexity"
end
