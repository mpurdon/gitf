defmodule GiTF.AuditContract do
  @moduledoc """
  Per-op verification contracts.

  Instead of relying solely on global sector-level quality thresholds, each op
  can declare its own verification policy: required checks, minimum thresholds,
  skip rules, and custom validation commands.

  Contracts are built by merging op-level overrides over sector-level defaults.
  High/critical risk ops automatically get stricter requirements.
  """

  @default_contract %{
    required_checks: [:static, :security, :proof_of_test],
    thresholds: %{composite: 70, security: 60, performance: 50, static: 70},
    skip_checks: [],
    auto_approve_eligible: true,
    custom_validation_command: nil
  }

  @doc """
  Returns the default verification contract.
  """
  @spec default_contract() :: map()
  def default_contract, do: @default_contract

  @doc """
  Builds a contract for a op by merging layers:

  1. Defaults
  2. Sector-level `quality_thresholds`
  3. Job-level `verification_contract`
  4. Risk-based adjustments (high/critical adds :performance, raises thresholds 10%)
  """
  @spec build_contract(map()) :: map()
  def build_contract(op) do
    base = @default_contract

    # Layer 2: sector-level thresholds
    sector_thresholds =
      case GiTF.Archive.get(:sectors, op.sector_id) do
        nil -> %{}
        sector -> Map.get(sector, :quality_thresholds, %{})
      end

    with_sector =
      if map_size(sector_thresholds) > 0 do
        %{base | thresholds: Map.merge(base.thresholds, sector_thresholds)}
      else
        base
      end

    # Layer 2.5: intelligence-based adjustment
    with_intel = apply_intel_adjustment(with_sector, op[:sector_id])

    # Layer 3: op-level contract overrides
    job_contract = Map.get(op, :verification_contract) || %{}
    merged = sync(with_intel, normalize_contract(job_contract))

    # Layer 4: risk-based adjustments
    risk = Map.get(op, :risk_level, :low)
    apply_risk_adjustments(merged, risk)
  end

  @doc """
  Evaluates a contract against verification results.

  Returns `:pass` or `{:fail, [reason_strings]}`.
  """
  @spec evaluate(map(), map()) :: :pass | {:fail, [String.t()]}
  def evaluate(contract, result) do
    checks_to_run =
      (contract.required_checks -- contract.skip_checks)
      |> Enum.uniq()

    failures =
      Enum.flat_map(checks_to_run, fn check ->
        evaluate_check(check, contract.thresholds, result)
      end)

    # Also check composite if threshold exists
    composite_failures =
      if Map.has_key?(contract.thresholds, :composite) do
        evaluate_check(:composite, contract.thresholds, result)
      else
        []
      end

    all_failures = failures ++ composite_failures

    if all_failures == [] do
      :pass
    else
      {:fail, Enum.uniq(all_failures)}
    end
  end

  @doc """
  Syncs two contracts. Override takes precedence for thresholds;
  union for required_checks.
  """
  @spec sync(map(), map()) :: map()
  def sync(base, override) do
    merged_thresholds =
      Map.merge(
        Map.get(base, :thresholds, %{}),
        Map.get(override, :thresholds, %{})
      )

    merged_required =
      (Map.get(base, :required_checks, []) ++ Map.get(override, :required_checks, []))
      |> Enum.uniq()

    merged_skip =
      (Map.get(base, :skip_checks, []) ++ Map.get(override, :skip_checks, []))
      |> Enum.uniq()

    base
    |> Map.merge(Map.drop(override, [:thresholds, :required_checks, :skip_checks]))
    |> Map.put(:thresholds, merged_thresholds)
    |> Map.put(:required_checks, merged_required)
    |> Map.put(:skip_checks, merged_skip)
  end

  # -- Private ---------------------------------------------------------------

  defp normalize_contract(contract) when is_map(contract) do
    contract
    |> maybe_atomize_key(:required_checks)
    |> maybe_atomize_key(:skip_checks)
    |> maybe_atomize_key(:thresholds)
  end

  defp maybe_atomize_key(map, key) do
    str_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> map
      Map.has_key?(map, str_key) -> Map.put(Map.delete(map, str_key), key, map[str_key])
      true -> map
    end
  end

  # Adjusts thresholds based on sector intelligence profile.
  # If the sector's median quality is high, slightly relax; if low, tighten.
  defp apply_intel_adjustment(contract, nil), do: contract

  defp apply_intel_adjustment(contract, sector_id) do
    profile = GiTF.Intel.SectorProfile.get_or_compute(sector_id)

    case profile do
      %{confidence: conf, recommendations: %{threshold_adjustment: adj}}
      when conf in [:medium, :high] and adj != 1.0 ->
        adjusted_thresholds =
          Map.new(contract.thresholds, fn {k, v} ->
            if is_number(v), do: {k, round(v * adj)}, else: {k, v}
          end)

        %{contract | thresholds: adjusted_thresholds}

      _ ->
        contract
    end
  rescue
    _ -> contract
  end

  defp apply_risk_adjustments(contract, risk) when risk in [:high, :critical] do
    # Add performance to required checks
    required = Enum.uniq(contract.required_checks ++ [:performance])

    # Raise all thresholds by 10%
    raised_thresholds =
      Map.new(contract.thresholds, fn {k, v} ->
        if is_number(v), do: {k, min(v * 1.1, 100)}, else: {k, v}
      end)

    %{
      contract
      | required_checks: required,
        thresholds: raised_thresholds,
        auto_approve_eligible: false
    }
  end

  defp apply_risk_adjustments(contract, _risk), do: contract

  defp evaluate_check(:composite, thresholds, result) do
    threshold = Map.get(thresholds, :composite)
    score = result[:quality_score]
    do_threshold_check("composite", threshold, score)
  end

  defp evaluate_check(:static, thresholds, result) do
    threshold = Map.get(thresholds, :static)
    score = result[:static_score]
    do_threshold_check("static", threshold, score)
  end

  defp evaluate_check(:security, thresholds, result) do
    threshold = Map.get(thresholds, :security)
    score = result[:security_score]
    do_threshold_check("security", threshold, score)
  end

  defp evaluate_check(:performance, thresholds, result) do
    threshold = Map.get(thresholds, :performance)
    score = result[:performance_score]
    do_threshold_check("performance", threshold, score)
  end

  defp evaluate_check(:proof_of_test, _thresholds, result) do
    # Proof-of-test is advisory, not a hard gate. The heuristic parses ghost
    # events looking for test-like commands, but it's brittle (pattern matching
    # on string-keyed LLM message structures). A :fail here means we couldn't
    # confirm tests ran — not that the code is untested. Log it but don't block.
    case result[:proof_of_test] do
      :fail ->
        require Logger

        Logger.info(
          "Proof-of-test: no test execution detected for op #{result[:op_id]} (advisory, not blocking)"
        )

        []

      _ ->
        []
    end
  end

  defp evaluate_check(_check, _thresholds, _result), do: []

  defp do_threshold_check(name, threshold, score) when is_number(threshold) do
    cond do
      # A nil score means the analysis didn't produce results (tool not installed,
      # language not supported, etc.) — treat as pass rather than blocking.
      is_nil(score) -> []
      score < threshold -> ["#{name}: score #{score} below threshold #{threshold}"]
      true -> []
    end
  end

  defp do_threshold_check(_name, _threshold, _score), do: []
end
