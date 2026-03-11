defmodule GiTF.Clearance do
  @moduledoc """
  Graduated clearance system.

  Models that build strong reputations earn relaxed verification thresholds.
  New or poorly-performing models get strict verification. Uses
  `GiTF.Trust` data to determine the appropriate level.

  Levels (from strictest to most relaxed):
  - `:strict`       — success_rate < 0.60 AND total_jobs >= 5
  - `:standard`     — default / new models
  - `:relaxed`      — success_rate >= 0.85 AND total_jobs >= 10
  - `:auto_approve` — success_rate >= 0.95 AND total_jobs >= 20
  """

  @doc """
  Determines the verification level for a op based on model trust.
  """
  @spec verification_level(map()) :: :strict | :standard | :relaxed | :auto_approve
  def verification_level(op) do
    model = normalize_model(op[:assigned_model])
    op_type = op[:op_type]

    rep = GiTF.Trust.model_reputation(model, op_type)
    compute_level(rep)
  end

  @doc """
  Adjusts verification thresholds based on clearance level.

  Returns a new thresholds map with values scaled according to level.
  """
  @spec adjusted_thresholds(map(), atom()) :: map()
  def adjusted_thresholds(base_thresholds, :strict) do
    scale_thresholds(base_thresholds, 1.2)
  end

  def adjusted_thresholds(base_thresholds, :standard) do
    base_thresholds
  end

  def adjusted_thresholds(base_thresholds, :relaxed) do
    scale_thresholds(base_thresholds, 0.8)
  end

  def adjusted_thresholds(_base_thresholds, :auto_approve) do
    %{security: 0, performance: 0, composite: 0}
  end

  @doc """
  Returns true if a op should be auto-merged (skip verification entirely).

  Only for `:auto_approve` clearance AND `:low` risk ops.
  """
  @spec should_auto_merge?(map()) :: boolean()
  def should_auto_merge?(op) do
    verification_level(op) == :auto_approve and
      Map.get(op, :risk_level, :low) == :low
  end

  # -- Private ---------------------------------------------------------------

  defp compute_level(nil), do: :standard

  defp compute_level(%{success_rate: rate, total_jobs: total}) do
    cond do
      rate >= 0.95 and total >= 20 -> :auto_approve
      rate >= 0.85 and total >= 10 -> :relaxed
      rate < 0.60 and total >= 5 -> :strict
      true -> :standard
    end
  end

  defp scale_thresholds(thresholds, factor) do
    Map.new(thresholds, fn {key, value} ->
      if is_number(value) do
        {key, value * factor}
      else
        {key, value}
      end
    end)
  end

  defp normalize_model(nil), do: nil

  defp normalize_model(model) when is_binary(model) do
    model
    |> String.replace("claude-", "")
    |> String.split("-")
    |> hd()
  end

  defp normalize_model(model) when is_atom(model), do: normalize_model(Atom.to_string(model))
end
