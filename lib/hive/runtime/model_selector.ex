defmodule Hive.Runtime.ModelSelector do
  @moduledoc """
  Intelligent model selection based on job type and capabilities.
  
  Selects the optimal model for each job type to balance quality and cost:
  - Planning/Architecture: Opus (complex reasoning)
  - Implementation: Opus (complex) or Sonnet (standard)
  - Research/Analysis: Haiku (fast, cost-effective)
  - Verification: Haiku (simple checking)
  - Summarization: Haiku (context compression)
  """

  @type job_type ::
          :planning
          | :implementation
          | :research
          | :summarization
          | :verification
          | :refactoring
          | :simple_fix

  @type complexity :: :simple | :moderate | :complex

  @type model_info :: %{
          name: String.t(),
          capabilities: [atom()],
          cost_tier: :low | :medium | :high,
          context_limit: integer(),
          strengths: [String.t()]
        }

  @doc """
  Get model capabilities registry for Claude models.
  """
  def model_registry do
    %{
      "opus" => %{
        capabilities: [:planning, :complex_implementation, :architecture, :refactoring],
        cost_tier: :high,
        context_limit: 200_000,
        strengths: ["complex reasoning", "large refactors", "system design"]
      },
      "sonnet" => %{
        capabilities: [:implementation, :refactoring, :debugging, :moderate_complexity],
        cost_tier: :medium,
        context_limit: 200_000,
        strengths: ["balanced performance", "general coding", "moderate complexity"]
      },
      "haiku" => %{
        capabilities: [:research, :summarization, :simple_fixes, :verification, :analysis],
        cost_tier: :low,
        context_limit: 200_000,
        strengths: ["fast responses", "simple tasks", "analysis", "cost-effective"]
      }
    }
  end

  @doc """
  Select the optimal model for a job based on type and complexity.
  
  ## Examples
  
      iex> select_model_for_job(:planning, :complex)
      "claude-opus"
      
      iex> select_model_for_job(:research, :simple)
      "claude-haiku"
      
      iex> select_model_for_job(:implementation, :moderate)
      "claude-sonnet"
  """
  @spec select_model_for_job(job_type(), complexity()) :: String.t()
  def select_model_for_job(job_type, complexity \\ :moderate)

  def select_model_for_job(:planning, _complexity), do: "opus"
  def select_model_for_job(:architecture, _complexity), do: "opus"

  def select_model_for_job(:implementation, :complex), do: "opus"
  def select_model_for_job(:implementation, :moderate), do: "sonnet"
  def select_model_for_job(:implementation, :simple), do: "haiku"

  def select_model_for_job(:research, _complexity), do: "haiku"
  def select_model_for_job(:summarization, _complexity), do: "haiku"
  def select_model_for_job(:verification, _complexity), do: "haiku"
  def select_model_for_job(:simple_fix, _complexity), do: "haiku"

  def select_model_for_job(:refactoring, :complex), do: "opus"
  def select_model_for_job(:refactoring, _complexity), do: "sonnet"

  # Default to haiku for unknown types (cost-effective)
  def select_model_for_job(_job_type, _complexity), do: "haiku"

  @doc """
  Get model information from the registry.
  """
  @spec get_model_info(String.t()) :: {:ok, model_info()} | {:error, :not_found}
  def get_model_info(model_name) do
    case Map.get(model_registry(), model_name) do
      nil -> {:error, :not_found}
      info -> {:ok, Map.put(info, :name, model_name)}
    end
  end

  @doc """
  Recommend a model for a job map.

  If the job has a `quest_id`, checks the remaining budget.
  When budget is below 30%, downgrades the model one tier.
  """
  @spec recommend_for_job(map()) :: String.t()
  def recommend_for_job(%{} = job) do
    quest_id = job[:quest_id] || job["quest_id"]

    # When quest context exists, use multi-objective selector
    if quest_id do
      try do
        {model, _breakdown} = Hive.Runtime.MultiObjectiveSelector.select_optimal(job)
        model
      rescue
        _ -> fallback_recommend(job, quest_id)
      end
    else
      fallback_recommend(job, nil)
    end
  end

  defp fallback_recommend(job, quest_id) do
    job_type = parse_job_type(job[:job_type] || job["job_type"])
    complexity = parse_complexity(job[:complexity] || job["complexity"])
    static_model = select_model_for_job(job_type, complexity)

    base_model =
      try do
        case Hive.Reputation.recommend_model(job_type, complexity) do
          model when is_binary(model) and model != "" -> model
          _ -> static_model
        end
      rescue
        _ -> static_model
      end

    # Prefer identity-based recommendation when available
    identity_model = identity_recommend(job_type, base_model)

    maybe_downgrade_for_budget(identity_model, quest_id)
  end

  defp identity_recommend(job_type, fallback) do
    job_type_str = to_string(job_type)
    available = list_models()

    case Hive.AgentIdentity.recommend_model_for(job_type_str, available) do
      {:ok, model} -> model
      {:error, :no_data} -> fallback
    end
  rescue
    _ -> fallback
  end

  @doc """
  List all available models.
  """
  @spec list_models() :: [String.t()]
  def list_models do
    Map.keys(model_registry())
  end

  @doc """
  Get models by capability.
  """
  @spec models_with_capability(atom()) :: [String.t()]
  def models_with_capability(capability) do
    model_registry()
    |> Enum.filter(fn {_name, info} -> capability in info.capabilities end)
    |> Enum.map(fn {name, _info} -> name end)
  end

  @doc """
  Get the cheapest model that can handle a job type.
  """
  @spec cheapest_model_for_job(job_type()) :: String.t()
  def cheapest_model_for_job(job_type) do
    capability = job_type_to_capability(job_type)

    model_registry()
    |> Enum.filter(fn {_name, info} -> capability in info.capabilities end)
    |> Enum.sort_by(fn {_name, info} -> cost_tier_value(info.cost_tier) end)
    |> List.first()
    |> case do
      {name, _info} -> name
      nil -> "claude-sonnet"
    end
  end

  # Private helpers

  defp parse_job_type(nil), do: :implementation
  defp parse_job_type(type) when is_atom(type), do: type
  defp parse_job_type(type) when is_binary(type) do
    String.to_existing_atom(type)
  rescue
    ArgumentError -> :implementation
  end

  defp parse_complexity(nil), do: :moderate
  defp parse_complexity(complexity) when is_atom(complexity), do: complexity
  defp parse_complexity(complexity) when is_binary(complexity) do
    String.to_existing_atom(complexity)
  rescue
    ArgumentError -> :moderate
  end

  defp job_type_to_capability(:planning), do: :planning
  defp job_type_to_capability(:implementation), do: :implementation
  defp job_type_to_capability(:research), do: :research
  defp job_type_to_capability(:summarization), do: :summarization
  defp job_type_to_capability(:verification), do: :verification
  defp job_type_to_capability(:refactoring), do: :refactoring
  defp job_type_to_capability(:simple_fix), do: :simple_fixes
  defp job_type_to_capability(_), do: :implementation

  defp cost_tier_value(:low), do: 1
  defp cost_tier_value(:medium), do: 2
  defp cost_tier_value(:high), do: 3

  # Budget-aware model downgrade: if <30% budget remains, drop one tier
  defp maybe_downgrade_for_budget(model, nil), do: model

  defp maybe_downgrade_for_budget(model, quest_id) do
    budget_pct = Hive.Config.Thresholds.get(:budget_downgrade_pct)

    remaining = Hive.Budget.remaining(quest_id)
    total = Hive.Budget.budget_for(quest_id)

    cond do
      total <= 0 ->
        model

      remaining / total < 0.05 ->
        # Emergency: <5% budget — force haiku for everything
        Hive.Telemetry.emit([:hive, :alert, :raised], %{}, %{
          type: :budget_emergency,
          message: "Quest #{quest_id} at #{Float.round(remaining / total * 100, 1)}% budget — forcing haiku"
        })
        "haiku"

      remaining / total < budget_pct ->
        downgraded = downgrade(model)
        if downgraded != model do
          Hive.Telemetry.emit([:hive, :model, :downgraded], %{}, %{
            quest_id: quest_id,
            from: model,
            to: downgraded,
            budget_remaining_pct: Float.round(remaining / total * 100, 1)
          })
        end
        downgraded

      true ->
        model
    end
  rescue
    _ -> model
  end

  defp downgrade("opus"), do: "sonnet"
  defp downgrade("sonnet"), do: "haiku"
  # Legacy names
  defp downgrade("claude-opus"), do: "sonnet"
  defp downgrade("claude-sonnet"), do: "haiku"
  defp downgrade(model), do: model
end
