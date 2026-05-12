defmodule GiTF.Intel do
  @moduledoc """
  Adaptive intel system for learning from failures and successes.
  """

  alias GiTF.Intel.{
    DecayDetector,
    FailureAnalysis,
    PromptContext,
    Retry,
    SectorProfile,
    SuccessPatterns
  }

  alias GiTF.Archive

  @doc """
  Analyze a failed op and suggest retry strategy.
  """
  def analyze_and_suggest(op_id) do
    with {:ok, analysis} <- FailureAnalysis.analyze_failure(op_id) do
      strategy = Retry.recommend_strategy(analysis.failure_type)

      {:ok,
       %{
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

  # -- Sector Intelligence API -------------------------------------------------

  @doc """
  Returns the intelligence profile for a sector (cached, lazy-computed).
  """
  def get_sector_profile(sector_id) do
    SectorProfile.get_or_compute(sector_id)
  end

  @doc """
  Returns compact historical context for a sector+phase prompt injection.

  When `mission` is provided AND the knowledge engine is enabled, the
  Karpathy-style wiki context (sector indexes + top-K relevant pages) is
  appended to the historical context. Backward compatible: the old
  arity-2 form remains for callers without a mission in hand.
  """
  def get_prompt_context(sector_id, phase) do
    PromptContext.for_phase(sector_id, phase)
  end

  def get_prompt_context(sector_id, phase, mission) when is_map(mission) do
    historical = PromptContext.for_phase(sector_id, phase)
    knowledge = GiTF.Knowledge.PromptContext.for_phase(sector_id, phase, mission)

    [historical, knowledge]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  @doc """
  Returns model health status for a sector.

  Returns a list of declining models with severity and metric info.
  """
  def check_model_health(sector_id) do
    DecayDetector.declining_models(sector_id)
  end

  @doc """
  Returns global model health across all sectors.
  """
  def global_model_health do
    DecayDetector.global_health()
  end

  defp get_top_failure_type(patterns) when length(patterns) > 0 do
    hd(patterns).type
  end

  defp get_top_failure_type(_), do: nil
end
