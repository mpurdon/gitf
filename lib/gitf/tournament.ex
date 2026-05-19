defmodule GiTF.Tournament do
  @moduledoc """
  Tournament evaluator for parallel implementation variants.

  When `:parallel_impl_attempts` is `> 1`, the implementation phase
  spawns N impl ghosts on N branches (`mission-<id>-v1`, `-v2`, ...).
  Each variant produces its own validation artifact (`validation_v1`,
  `validation_v2`, ...). This module scores each variant and picks the
  winner — the one whose branch should land on main.

  ## Scoring

  Higher is better. The score is a composite of:

    * `overall_verdict`: `pass` = +100 base, `fail`/unset = 0 base
    * `requirements_met`: percentage of must-have requirements met,
      scaled to ±50.
    * `gaps`: each gap subtracts 10.
    * Cross-check feasibility: a `cross_check_override` (validator said
      pass but no impl commits) drops the variant to `:disqualified`.

  Ties break in favour of the variant with the lower index (`v1` over
  `v2`) — earliest spawn wins, consistent with how the rest of the
  pipeline treats variant ordering.

  ## API

      GiTF.Tournament.score(validation_artifact)
      # => %{score: 92.0, verdict: :pass, gaps: 1, requirements_met: 5, ...}

      GiTF.Tournament.rank(mission)
      # => [%{variant: "v1", score: 92.0, ...}, %{variant: "v2", ...}, ...]

      GiTF.Tournament.pick_winner(mission)
      # => {:ok, "v1"} | {:error, :no_variants} | {:error, :all_disqualified}

  All functions are pure (`mission` is read for its `artifacts` and
  `impl_variants` fields only); the caller decides what to do with the
  result (rewrite `mission.winning_variant`, dispatch sync of the
  winner's branch, archive the loser branches, etc.).
  """

  @disqualified_score -1_000.0
  @min_attempts 1
  @max_attempts 3

  @type variant_id :: String.t()
  @type score_breakdown :: %{
          score: float() | :disqualified,
          verdict: :pass | :fail | :unknown,
          requirements_total: non_neg_integer(),
          requirements_met: non_neg_integer(),
          gaps: non_neg_integer(),
          disqualified_reason: String.t() | nil
        }

  @doc """
  The number of implementation variants to spawn per mission, clamped
  to `1..3`. Read from the `:parallel_impl_attempts` flag (env override
  `GITF_PARALLEL_IMPL_ATTEMPTS`). Default `1` (single variant —
  tournament disabled).
  """
  @spec configured_attempts() :: pos_integer()
  def configured_attempts do
    case Application.get_env(:gitf, :parallel_impl_attempts, @min_attempts) do
      n when is_integer(n) -> n |> max(@min_attempts) |> min(@max_attempts)
      n when is_binary(n) -> n |> String.to_integer() |> max(@min_attempts) |> min(@max_attempts)
      _ -> @min_attempts
    end
  rescue
    _ -> @min_attempts
  end

  @doc """
  Is parallel-impl tournament mode active for this mission? `true` when
  `configured_attempts() > 1`. Operator-authored workflows can override
  via per-mission state in the future; today the flag is global.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: configured_attempts() > 1

  @doc """
  Build the variant-id list a mission with `attempts` parallel impls
  should run. `["v1", "v2", "v3"]` for `attempts=3`.
  """
  @spec variant_ids(pos_integer()) :: [variant_id()]
  def variant_ids(attempts) when is_integer(attempts) and attempts >= 1 do
    Enum.map(1..attempts, &"v#{&1}")
  end

  @doc """
  Score a single validation artifact.
  """
  @spec score(map() | nil) :: score_breakdown()
  def score(nil) do
    %{
      score: @disqualified_score,
      verdict: :unknown,
      requirements_total: 0,
      requirements_met: 0,
      gaps: 0,
      disqualified_reason: "no validation artifact"
    }
  end

  def score(artifact) when is_map(artifact) do
    verdict = parse_verdict(artifact)
    requirements = Map.get(artifact, "requirements_met", []) || []
    requirements_total = length(requirements)
    requirements_met = Enum.count(requirements, &(Map.get(&1, "met") == true))
    gaps = length(Map.get(artifact, "gaps", []) || [])
    disqualified = Map.get(artifact, "cross_check_override")

    cond do
      is_binary(disqualified) ->
        %{
          score: :disqualified,
          verdict: verdict,
          requirements_total: requirements_total,
          requirements_met: requirements_met,
          gaps: gaps,
          disqualified_reason: "cross_check_override: #{disqualified}"
        }

      true ->
        verdict_score = if verdict == :pass, do: 100.0, else: 0.0

        requirements_score =
          if requirements_total > 0 do
            requirements_met / requirements_total * 50.0
          else
            0.0
          end

        gap_penalty = gaps * 10.0

        %{
          score: verdict_score + requirements_score - gap_penalty,
          verdict: verdict,
          requirements_total: requirements_total,
          requirements_met: requirements_met,
          gaps: gaps,
          disqualified_reason: nil
        }
    end
  end

  @doc """
  Rank all variants in `mission.impl_variants` by their validation
  artifacts (`validation_v1`, `validation_v2`, ...). Returns a list of
  `%{variant: id, score: number | :disqualified, ...}` maps sorted by
  score descending.

  An empty `impl_variants` list (or `nil`) returns `[]` — the caller
  should fall back to the single-variant `validation` artifact.
  """
  @spec rank(map()) :: [map()]
  def rank(%{} = mission) do
    variants = Map.get(mission, :impl_variants) || []
    artifacts = Map.get(mission, :artifacts) || %{}

    variants
    |> Enum.map(fn variant_id ->
      artifact = Map.get(artifacts, "validation_#{variant_id}")
      score(artifact) |> Map.put(:variant, variant_id)
    end)
    |> Enum.sort_by(&{rank_key(&1.score), variant_index(&1.variant)})
  end

  @doc """
  Pick the winning variant id. Returns `{:ok, variant_id}` when there's
  at least one non-disqualified variant, `{:error, :all_disqualified}`
  when every variant failed the cross-check or has no artifact, or
  `{:error, :no_variants}` when the mission isn't running a
  tournament (empty `impl_variants`).
  """
  @spec pick_winner(map()) ::
          {:ok, variant_id()} | {:error, :no_variants | :all_disqualified}
  def pick_winner(mission) do
    case rank(mission) do
      [] ->
        {:error, :no_variants}

      ranked ->
        case Enum.find(ranked, &(&1.score != :disqualified)) do
          nil -> {:error, :all_disqualified}
          %{variant: id} -> {:ok, id}
        end
    end
  end

  @doc """
  Are all of `mission.impl_variants` terminal (each has either a
  validation artifact or a recorded failure)? Used by
  `Phases.Validation.verdict/2` to decide whether the tournament can
  run yet, or whether some variants are still in flight.
  """
  @spec ready?(map()) :: boolean()
  def ready?(%{} = mission) do
    variants = Map.get(mission, :impl_variants) || []
    artifacts = Map.get(mission, :artifacts) || %{}

    variants != [] and
      Enum.all?(variants, fn variant_id ->
        Map.has_key?(artifacts, "validation_#{variant_id}")
      end)
  end

  # -- Helpers ----------------------------------------------------------------

  defp parse_verdict(artifact) do
    case Map.get(artifact, "overall_verdict") do
      v when v in ["pass", "passed"] -> :pass
      v when v in ["fail", "failed"] -> :fail
      _ -> :unknown
    end
  end

  # Sort by score descending. `:disqualified` sorts last regardless of
  # original score. We invert numeric scores via negation so the
  # default ascending Enum.sort_by yields highest-first.
  defp rank_key(:disqualified), do: {1, 0}
  defp rank_key(score) when is_number(score), do: {0, -score}

  # Parse "v1" → 1, "v2" → 2, etc. Used as a tie-breaker so ties favour
  # the earlier-spawned variant.
  defp variant_index("v" <> rest) do
    case Integer.parse(rest) do
      {n, ""} -> n
      _ -> 999
    end
  end

  defp variant_index(_), do: 999
end
