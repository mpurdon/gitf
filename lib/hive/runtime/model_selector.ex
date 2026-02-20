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
      "claude-opus" => %{
        capabilities: [:planning, :complex_implementation, :architecture, :refactoring],
        cost_tier: :high,
        context_limit: 200_000,
        strengths: ["complex reasoning", "large refactors", "system design"]
      },
      "claude-sonnet" => %{
        capabilities: [:implementation, :refactoring, :debugging, :moderate_complexity],
        cost_tier: :medium,
        context_limit: 200_000,
        strengths: ["balanced performance", "general coding", "moderate complexity"]
      },
      "claude-haiku" => %{
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

  def select_model_for_job(:planning, _complexity), do: "claude-opus"
  def select_model_for_job(:architecture, _complexity), do: "claude-opus"

  def select_model_for_job(:implementation, :complex), do: "claude-opus"
  def select_model_for_job(:implementation, :moderate), do: "claude-sonnet"
  def select_model_for_job(:implementation, :simple), do: "claude-haiku"

  def select_model_for_job(:research, _complexity), do: "claude-haiku"
  def select_model_for_job(:summarization, _complexity), do: "claude-haiku"
  def select_model_for_job(:verification, _complexity), do: "claude-haiku"
  def select_model_for_job(:simple_fix, _complexity), do: "claude-haiku"

  def select_model_for_job(:refactoring, :complex), do: "claude-opus"
  def select_model_for_job(:refactoring, _complexity), do: "claude-sonnet"

  # Default to sonnet for unknown types
  def select_model_for_job(_job_type, _complexity), do: "claude-sonnet"

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
    job_type = parse_job_type(job[:job_type] || job["job_type"])
    complexity = parse_complexity(job[:complexity] || job["complexity"])
    base_model = select_model_for_job(job_type, complexity)

    quest_id = job[:quest_id] || job["quest_id"]
    maybe_downgrade_for_budget(base_model, quest_id)
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
  defp parse_job_type(type) when is_binary(type), do: String.to_existing_atom(type)

  defp parse_complexity(nil), do: :moderate
  defp parse_complexity(complexity) when is_atom(complexity), do: complexity
  defp parse_complexity(complexity) when is_binary(complexity), do: String.to_existing_atom(complexity)

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

    if total > 0 and remaining / total < budget_pct do
      downgrade(model)
    else
      model
    end
  rescue
    _ -> model
  end

  defp downgrade("claude-opus"), do: "claude-sonnet"
  defp downgrade("claude-sonnet"), do: "claude-haiku"
  defp downgrade(model), do: model
end
