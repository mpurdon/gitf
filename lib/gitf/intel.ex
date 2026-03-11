defmodule GiTF.Intel do
  @moduledoc """
  Adaptive intel system for learning from failures and successes.
  """

  alias GiTF.Intel.FailureAnalysis
  alias GiTF.Intel.Retry
  alias GiTF.Intel.SuccessPatterns
  alias GiTF.Archive

  @doc """
  Analyze a failed op and suggest retry strategy.
  """
  def analyze_and_suggest(op_id) do
    with {:ok, analysis} <- FailureAnalysis.analyze_failure(op_id) do
      strategy = Retry.recommend_strategy(analysis.failure_type)
      
      {:ok, %{
        analysis: analysis,
        recommended_strategy: strategy,
        suggestions: analysis.suggestions
      }}
    end
  end

  @doc """
  Analyze a successful op to learn patterns.
  """
  def analyze_success(op_id) do
    SuccessPatterns.analyze_success(op_id)
  end

  @doc """
  Get best practices for a sector.
  """
  def get_best_practices(sector_id) do
    SuccessPatterns.get_best_practices(sector_id)
  end

  @doc """
  Recommend approach for a new op.
  """
  def recommend_approach(sector_id, op_description \\ "") do
    SuccessPatterns.recommend_approach(sector_id, op_description)
  end

  @doc """
  Automatically retry a failed op with intelligent strategy.
  """
  def auto_retry(op_id) do
    Retry.retry_with_strategy(op_id)
  end

  @doc """
  Get intel insights for a sector.
  """
  def get_insights(sector_id) do
    patterns = FailureAnalysis.get_failure_patterns(sector_id)
    
    ops = Archive.filter(:ops, &(&1.sector_id == sector_id))
    total = length(ops)
    failed = Enum.count(ops, &(&1.status == "failed"))
    success_rate = if total > 0, do: (total - failed) / total * 100, else: 0
    
    %{
      sector_id: sector_id,
      total_jobs: total,
      failed_jobs: failed,
      success_rate: Float.round(success_rate, 1),
      failure_patterns: patterns,
      top_failure_type: get_top_failure_type(patterns)
    }
  end

  @doc """
  Learn from all failures in a sector.
  """
  def learn(sector_id) do
    FailureAnalysis.learn_from_failures(sector_id)
  end

  defp get_top_failure_type(patterns) when length(patterns) > 0 do
    hd(patterns).type
  end
  
  defp get_top_failure_type(_), do: nil
end
