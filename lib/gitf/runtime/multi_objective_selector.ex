defmodule GiTF.Runtime.MultiObjectiveSelector do
  @moduledoc """
  Multi-objective model selector that balances quality, cost, and budget.

  Replaces simple budget-downgrade logic with a weighted scoring system:
  - Quality score (weight 0.5): from model trust success_rate
  - Cost score (weight 0.3): inverted cost tier (haiku cheapest)
  - Budget score (weight 0.2): penalizes expensive models when budget is low

  Risk adjustment shifts weight from cost to quality for high/critical ops.
  """

  @candidates ["opus", "sonnet", "haiku"]

  @cost_scores %{
    "haiku" => 1.0,
    "sonnet" => 0.66,
    "opus" => 0.33
  }

  @cost_tiers %{
    "haiku" => 0.01,
    "sonnet" => 0.10,
    "opus" => 0.50
  }

  @doc """
  Selects the optimal model for a op using multi-objective scoring.

  Returns `{model, score_breakdown}` where score_breakdown contains
  individual scores and the weighted total.
  """
  @spec select_optimal(map(), keyword()) :: {String.t(), map()}
  def select_optimal(op, _opts \\ []) do
    mission_id = op[:mission_id]
    op_type = op[:op_type] || :implementation
    risk_level = op[:risk_level] || :low

    {quality_weight, cost_weight, budget_weight} = weights_for_risk(risk_level)

    scored =
      @candidates
      |> Enum.map(fn model ->
        quality = quality_score(model, op_type)
        cost = cost_score(model)
        budget = budget_score(model, mission_id)

        total =
          quality * quality_weight +
            cost * cost_weight +
            budget * budget_weight

        breakdown = %{
          model: model,
          quality: quality,
          cost: cost,
          budget: budget,
          total: total,
          weights: %{quality: quality_weight, cost: cost_weight, budget: budget_weight}
        }

        {model, breakdown}
      end)
      |> Enum.sort_by(fn {_model, b} -> b.total end, :desc)

    case scored do
      [{model, breakdown} | _] -> {model, breakdown}
      [] -> {"sonnet", %{total: 0.0}}
    end
  end

  @doc """
  Returns score breakdowns for all candidates (for debugging/display).
  """
  @spec score_breakdown(map()) :: map()
  def score_breakdown(op) do
    {_best, _} = select_optimal(op)

    mission_id = op[:mission_id]
    op_type = op[:op_type] || :implementation
    risk_level = op[:risk_level] || :low
    {quality_weight, cost_weight, budget_weight} = weights_for_risk(risk_level)

    candidates =
      @candidates
      |> Enum.map(fn model ->
        quality = quality_score(model, op_type)
        cost = cost_score(model)
        budget = budget_score(model, mission_id)

        total =
          quality * quality_weight +
            cost * cost_weight +
            budget * budget_weight

        {model,
         %{
           quality: quality,
           cost: cost,
           budget: budget,
           total: total
         }}
      end)
      |> Map.new()

    %{
      candidates: candidates,
      weights: %{quality: quality_weight, cost: cost_weight, budget: budget_weight},
      risk_level: risk_level
    }
  end

  # -- Private ---------------------------------------------------------------

  defp weights_for_risk(risk) when risk in [:high, :critical] do
    # Shift weight from cost to quality for risky ops
    {0.65, 0.15, 0.20}
  end

  defp weights_for_risk(_) do
    {0.50, 0.30, 0.20}
  end

  defp quality_score(model, op_type) do
    case GiTF.Trust.model_reputation(model, op_type) do
      %{success_rate: rate} when is_number(rate) -> rate
      _ -> 0.5
    end
  rescue
    _ -> 0.5
  end

  defp cost_score(model) do
    Map.get(@cost_scores, model, 0.5)
  end

  defp budget_score(_model, nil), do: 1.0

  defp budget_score(model, mission_id) do
    remaining = GiTF.Budget.remaining(mission_id)
    total = GiTF.Budget.budget_for(mission_id)

    budget_ratio = if total > 0, do: remaining / total, else: 1.0

    model_cost = Map.get(@cost_tiers, model, 0.10)

    cond do
      # Budget healthy: no penalty
      budget_ratio >= 0.30 -> 1.0
      # Budget tight: penalize expensive models proportionally
      budget_ratio > 0 -> budget_ratio / 0.30 * (1.0 - model_cost)
      # Budget exhausted: only free models pass
      true -> 0.0
    end
  rescue
    _ -> 1.0
  end
end
