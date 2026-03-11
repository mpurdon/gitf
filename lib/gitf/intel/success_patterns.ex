defmodule GiTF.Intel.SuccessPatterns do
  @moduledoc """
  Identifies and learns from successful op patterns.
  """

  alias GiTF.Archive

  @doc """
  Analyze a successful op to identify success factors.
  """
  def analyze_success(op_id) do
    with {:ok, op} <- GiTF.Ops.get(op_id),
         true <- op.status == "done" do
      
      factors = identify_success_factors(op)
      quality_score = get_quality_score(op_id)
      
      pattern = %{
        id: generate_id("sp"),
        op_id: op_id,
        sector_id: op.sector_id,
        success_factors: factors,
        quality_score: quality_score,
        model_used: Map.get(op, :model),
        complexity: estimate_complexity(op),
        analyzed_at: DateTime.utc_now()
      }
      
      Archive.insert(:success_patterns, pattern)
      {:ok, pattern}
    else
      _ -> {:error, :not_successful_job}
    end
  end

  @doc """
  Get best practices for a sector based on successful ops.
  """
  def get_best_practices(sector_id) do
    patterns = Archive.filter(:success_patterns, &(&1.sector_id == sector_id))
    
    if Enum.empty?(patterns) do
      []
    else
      # Group by success factors
      factor_frequency = patterns
      |> Enum.flat_map(& &1.success_factors)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_, count} -> count end, :desc)
      |> Enum.take(5)
      
      # Find high-quality patterns
      high_quality = patterns
      |> Enum.filter(&(&1.quality_score && &1.quality_score >= 85))
      |> Enum.take(3)
      
      %{
        common_factors: Enum.map(factor_frequency, fn {factor, count} ->
          %{factor: factor, frequency: count / length(patterns)}
        end),
        high_quality_examples: Enum.map(high_quality, & &1.op_id),
        recommended_model: find_best_model(patterns),
        average_quality: calculate_average_quality(patterns)
      }
    end
  end

  @doc """
  Recommend approach for a new op based on success patterns.
  """
  def recommend_approach(sector_id, _op_description) do
    best_practices = get_best_practices(sector_id)
    
    # Handle empty list case
    common_factors = if is_list(best_practices) do
      []
    else
      best_practices.common_factors || []
    end
    
    if Enum.empty?(common_factors) do
      %{
        model: "claude-sonnet",
        confidence: :low,
        suggestions: ["No historical data available"]
      }
    else
      %{
        model: best_practices.recommended_model || "claude-sonnet",
        confidence: :medium,
        suggestions: generate_suggestions(best_practices),
        quality_expectation: best_practices.average_quality
      }
    end
  end

  # Private functions

  defp identify_success_factors(op) do
    factors = []
    
    # Model used
    factors = if Map.get(op, :model) do
      ["model_#{op.model}" | factors]
    else
      factors
    end
    
    # Audit passed
    factors = if Map.get(op, :verification_status) == "passed" do
      ["verification_passed" | factors]
    else
      factors
    end
    
    # Quality score
    quality = Map.get(op, :quality_score)
    factors = cond do
      quality && quality >= 90 -> ["high_quality" | factors]
      quality && quality >= 80 -> ["good_quality" | factors]
      true -> factors
    end
    
    # No retries
    factors = if is_nil(Map.get(op, :retry_of)) do
      ["first_attempt_success" | factors]
    else
      factors
    end
    
    # Fast completion (if we have timestamps)
    created = Map.get(op, :created_at)
    updated = Map.get(op, :updated_at)
    
    factors = if created && updated do
      duration = DateTime.diff(updated, created, :minute)
      cond do
        duration < 10 -> ["fast_completion" | factors]
        duration < 30 -> ["normal_completion" | factors]
        true -> factors
      end
    else
      factors
    end
    
    factors
  end

  defp get_quality_score(op_id) do
    GiTF.Quality.calculate_composite_score(op_id)
  end

  defp estimate_complexity(op) do
    # Simple heuristic based on description length
    desc_length = String.length(Map.get(op, :description, ""))
    
    cond do
      desc_length < 100 -> :simple
      desc_length < 300 -> :moderate
      true -> :complex
    end
  end

  defp find_best_model(patterns) do
    # Find model with highest average quality
    patterns
    |> Enum.filter(&(&1.model_used && &1.quality_score))
    |> Enum.group_by(& &1.model_used)
    |> Enum.map(fn {model, group} ->
      avg_quality = Enum.sum(Enum.map(group, & &1.quality_score)) / length(group)
      {model, avg_quality}
    end)
    |> Enum.max_by(fn {_, quality} -> quality end, fn -> {nil, 0} end)
    |> elem(0)
  end

  defp calculate_average_quality(patterns) do
    scores = patterns
    |> Enum.map(& &1.quality_score)
    |> Enum.reject(&is_nil/1)
    
    if Enum.empty?(scores) do
      nil
    else
      Float.round(Enum.sum(scores) / length(scores), 1)
    end
  end

  defp generate_suggestions(best_practices) do
    suggestions = []
    
    # Model suggestion
    suggestions = if best_practices.recommended_model do
      ["Use #{best_practices.recommended_model} (best success rate)" | suggestions]
    else
      suggestions
    end
    
    # Quality expectation
    suggestions = if best_practices.average_quality do
      ["Target quality score: #{best_practices.average_quality}/100" | suggestions]
    else
      suggestions
    end
    
    # Common success factors
    top_factors = best_practices.common_factors
    |> Enum.take(3)
    |> Enum.map(& &1.factor)
    
    suggestions = if length(top_factors) > 0 do
      ["Common success factors: #{Enum.join(top_factors, ", ")}" | suggestions]
    else
      suggestions
    end
    
    suggestions
  end

  defp generate_id(prefix) do
    "#{prefix}-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end
end
