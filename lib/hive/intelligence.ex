defmodule Hive.Intelligence do
  @moduledoc """
  Adaptive intelligence system for learning from failures and successes.
  """

  alias Hive.Intelligence.FailureAnalysis
  alias Hive.Intelligence.Retry
  alias Hive.Intelligence.SuccessPatterns
  alias Hive.Store

  @doc """
  Analyze a failed job and suggest retry strategy.
  """
  def analyze_and_suggest(job_id) do
    with {:ok, analysis} <- FailureAnalysis.analyze_failure(job_id) do
      strategy = Retry.recommend_strategy(analysis.failure_type)
      
      {:ok, %{
        analysis: analysis,
        recommended_strategy: strategy,
        suggestions: analysis.suggestions
      }}
    end
  end

  @doc """
  Analyze a successful job to learn patterns.
  """
  def analyze_success(job_id) do
    SuccessPatterns.analyze_success(job_id)
  end

  @doc """
  Get best practices for a comb.
  """
  def get_best_practices(comb_id) do
    SuccessPatterns.get_best_practices(comb_id)
  end

  @doc """
  Recommend approach for a new job.
  """
  def recommend_approach(comb_id, job_description \\ "") do
    SuccessPatterns.recommend_approach(comb_id, job_description)
  end

  @doc """
  Automatically retry a failed job with intelligent strategy.
  """
  def auto_retry(job_id) do
    Retry.retry_with_strategy(job_id)
  end

  @doc """
  Get intelligence insights for a comb.
  """
  def get_insights(comb_id) do
    patterns = FailureAnalysis.get_failure_patterns(comb_id)
    
    jobs = Store.filter(:jobs, &(&1.comb_id == comb_id))
    total = length(jobs)
    failed = Enum.count(jobs, &(&1.status == "failed"))
    success_rate = if total > 0, do: (total - failed) / total * 100, else: 0
    
    %{
      comb_id: comb_id,
      total_jobs: total,
      failed_jobs: failed,
      success_rate: Float.round(success_rate, 1),
      failure_patterns: patterns,
      top_failure_type: get_top_failure_type(patterns)
    }
  end

  @doc """
  Learn from all failures in a comb.
  """
  def learn(comb_id) do
    FailureAnalysis.learn_from_failures(comb_id)
  end

  defp get_top_failure_type(patterns) when length(patterns) > 0 do
    hd(patterns).type
  end
  
  defp get_top_failure_type(_), do: nil
end
