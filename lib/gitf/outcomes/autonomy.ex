defmodule GiTF.Outcomes.Autonomy do
  @moduledoc """
  Derives a per-sector autonomy tier from accumulated merge outcomes.

  Tiers:

    * `:trusted` — rate ≥ 0.9 and ≥ 20 samples. Low-risk work may skip
      approval that `:normal` would have required.
    * `:require_approval` — rate < 0.5 and ≥ 10 samples. Higher scrutiny;
      Override will force approval on every mission in this sector.
    * `:normal` — anything else, or insufficient data.

  Thresholds come from config so an operator can tune them without a
  redeploy. The computation is pure (reads `Trust.sector_merge_rate/1`,
  no writes) and cheap; call sites are expected to memoize via the Trust
  cache itself.

  Feature-gated by `:outcome_autonomy_tiers_enabled`. When the flag is
  off, every sector is `:normal`.
  """

  alias GiTF.Trust

  @type tier :: :trusted | :normal | :require_approval

  @doc """
  Returns the current tier for a sector, along with the reasoning map
  (rate, sample count, reason atom). Safe for any sector id.
  """
  @spec tier_for(String.t() | nil) :: %{
          tier: tier(),
          rate: float() | nil,
          sample_count: non_neg_integer(),
          reason: atom()
        }
  def tier_for(nil), do: %{tier: :normal, rate: nil, sample_count: 0, reason: :no_sector}

  def tier_for(sector_id) when is_binary(sector_id) do
    if enabled?() do
      case Trust.sector_merge_rate(sector_id) do
        nil ->
          %{tier: :normal, rate: nil, sample_count: 0, reason: :insufficient_data}

        %{rate: rate, sample_count: n} = _rep ->
          classify(rate, n)
      end
    else
      %{tier: :normal, rate: nil, sample_count: 0, reason: :feature_disabled}
    end
  end

  @doc "Same as tier_for/1 but returns just the tier atom."
  @spec tier(String.t() | nil) :: tier()
  def tier(sector_id), do: tier_for(sector_id).tier

  @doc """
  True when an operator override has been recorded on the sector record
  (`:autonomy_level`). Those manual overrides take precedence over the
  derived tier.
  """
  @spec override_for(String.t() | nil) :: tier() | nil
  def override_for(nil), do: nil

  def override_for(sector_id) when is_binary(sector_id) do
    case GiTF.Archive.get(:sectors, sector_id) do
      %{autonomy_level: level} when level in [:trusted, :normal, :require_approval] -> level
      _ -> nil
    end
  end

  @doc """
  Returns the effective tier after applying any operator override stored
  on the sector record.
  """
  @spec effective_tier(String.t() | nil) :: tier()
  def effective_tier(sector_id) do
    case override_for(sector_id) do
      nil -> tier(sector_id)
      override -> override
    end
  end

  # -- Private ---------------------------------------------------------------

  defp classify(rate, n) when is_number(rate) do
    trusted_rate = Application.get_env(:gitf, :autonomy_trusted_min_rate, 0.9)
    trusted_samples = Application.get_env(:gitf, :autonomy_trusted_min_samples, 20)
    approval_rate = Application.get_env(:gitf, :autonomy_require_approval_max_rate, 0.5)
    approval_samples = Application.get_env(:gitf, :autonomy_require_approval_min_samples, 10)

    cond do
      rate >= trusted_rate and n >= trusted_samples ->
        %{tier: :trusted, rate: rate, sample_count: n, reason: :rate_above_threshold}

      rate < approval_rate and n >= approval_samples ->
        %{tier: :require_approval, rate: rate, sample_count: n, reason: :rate_below_threshold}

      true ->
        %{tier: :normal, rate: rate, sample_count: n, reason: :within_normal_band}
    end
  end

  defp enabled? do
    Application.get_env(:gitf, :outcome_autonomy_tiers_enabled, false) == true
  end
end
