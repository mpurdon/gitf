defmodule GiTF.Verification do
  @moduledoc """
  Modality-aware behavioral verification — the "trustable gate" a dark factory
  needs beyond unit tests.

  A sector declares a **verification profile**: a modality (how its artifact is
  consumed) and a suite of **holdout scenarios** (natural-language user stories
  with steps + a prose expectation). Because the profile lives on the sector
  config in the workspace — NOT in the ghost worktrees — the ghosts cannot edit
  their own acceptance criteria, which is what makes the gate trustworthy
  (the same holdout property StrongDM's software factory relies on).

  `run/2` drives every scenario through the modality's driver
  (`GiTF.Verification.Driver`), captures a transcript, and has
  `GiTF.Verification.Judge` decide pass/fail per scenario. Fail-safe: any error
  or unverifiable scenario counts as a failure.

  Profile shape (on the sector record under `:verification_profile`):

      %{
        "modality" => "cli",
        "scenarios" => [
          %{"name" => "help output", "steps" => ["./mytool --help"],
            "expect" => "prints usage with a --version flag listed"},
          ...
        ]
      }
  """

  require Logger

  alias GiTF.Verification.{Driver, Judge}

  @type result :: %{
          passed: boolean(),
          total: non_neg_integer(),
          failures: [%{name: String.t(), reasoning: String.t()}]
        }

  @doc "Whether `sector_id` has a non-empty verification profile."
  @spec profile?(String.t() | nil) :: boolean()
  def profile?(nil), do: false

  def profile?(sector_id) do
    case profile(sector_id) do
      %{scenarios: [_ | _]} -> true
      _ -> false
    end
  end

  @doc "Loads and normalizes the sector's verification profile, or nil."
  @spec profile(String.t() | nil) :: %{modality: String.t(), scenarios: [map()]} | nil
  def profile(nil), do: nil

  def profile(sector_id) do
    case GiTF.Archive.get(:sectors, sector_id) do
      %{verification_profile: %{} = raw} -> normalize(raw)
      _ -> nil
    end
  end

  @doc """
  Runs the sector's verification suite against the artifact at `cwd`.

  Returns `{:ok, result}` when a profile exists and ran, or `:no_profile` when
  the sector has none (callers treat that as "not applicable", not a failure).
  """
  @spec run(String.t(), String.t()) :: {:ok, result()} | :no_profile
  def run(sector_id, cwd) do
    case profile(sector_id) do
      nil ->
        :no_profile

      %{modality: modality, scenarios: scenarios} ->
        case Driver.for_modality(modality) do
          {:ok, driver} ->
            {:ok, run_scenarios(driver, scenarios, sector_id, cwd)}

          {:error, :unknown_modality} ->
            Logger.warning("Verification: unknown modality #{inspect(modality)} — failing closed")

            {:ok,
             %{
               passed: false,
               total: length(scenarios),
               failures: [%{name: "profile", reasoning: "unknown modality #{modality}"}]
             }}
        end
    end
  end

  defp run_scenarios(driver, scenarios, sector_id, cwd) do
    context = %{cwd: cwd, sector_id: sector_id, risk_level: :low}

    judged =
      scenarios
      |> Task.async_stream(
        fn scenario ->
          transcript = driver.run(scenario, context)
          {scenario[:name] || "scenario", Judge.judge(scenario, transcript)}
        end,
        max_concurrency: 3,
        timeout: 180_000,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.map(fn
        {:ok, {name, verdict}} -> {name, verdict}
        # A killed/crashed task is a fail-safe failure.
        _ -> {"scenario", {:fail, "verification task did not complete"}}
      end)

    failures =
      for {name, {:fail, reasoning}} <- judged, do: %{name: name, reasoning: reasoning}

    %{passed: failures == [], total: length(scenarios), failures: failures}
  end

  # Accepts string- or atom-keyed profiles/scenarios and returns atom-keyed.
  defp normalize(raw) do
    scenarios =
      (get(raw, :scenarios) || [])
      |> Enum.map(fn s ->
        %{
          name: get(s, :name),
          expect: get(s, :expect),
          steps: get(s, :steps) || [],
          setup: get(s, :setup) || [],
          input: get(s, :input)
        }
      end)
      |> Enum.reject(&(is_nil(&1.name) or is_nil(&1.expect)))

    %{modality: get(raw, :modality) || "cli", scenarios: scenarios}
  end

  defp get(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
