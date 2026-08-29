defmodule GiTF.Major.ModelPolicy do
  @moduledoc """
  THE MODEL POLICY — the persona that decides WHICH mind does a piece of
  work. Every phase ghost is spawned with a tier (`fast` / `general` /
  `thinking`); this module turns that default into a concrete tier by
  consulting triage's complexity read and the sector's accumulated
  model-performance profile, then resolves the tier to a provider model
  id.

  It also owns `op_strategy/1` — the "which design variant is this op?"
  label — because the strategy label and the model choice are the two
  things that distinguish otherwise-identical parallel ghosts.

  Shaped by two pressures pulling opposite ways:

    * Cost: routing design/planning/review to `thinking` on a trivial
      mission pays a reasoning-model premium for work that `general`
      does identically. Triage's complexity read gates that spend.
    * Regression risk: complex and UNKNOWN complexity both keep
      `thinking`. An absent triage artifact must never silently
      downgrade hard work — unknown is treated as hard.

  Sector intelligence is applied by confidence, never blindly: at low
  confidence the caller's default stands; at medium the profile may only
  swap AWAY from a model that is actively declining; only at high
  confidence does the profile name the model outright. Every lookup is
  wrapped so a malformed profile degrades to the default rather than
  blocking a spawn.
  """

  @doc false
  def model_id(tier) do
    GiTF.Runtime.ModelResolver.resolve(tier)
  end

  # Routes design/planning/review to `general` (cheaper/faster) when triage
  # said trivial/simple/moderate. Complex and unknown keep `thinking` so we
  # don't regress on hard work.
  @doc false
  def phase_model_for_complexity(phase, mission) do
    case {phase, GiTF.Triage.mission_complexity(mission)} do
      {p, c} when p in ["design", "planning", "review"] and c in [:trivial, :simple, :moderate] ->
        "general"

      {p, _} when p in ["design", "planning", "review"] ->
        "thinking"

      _ ->
        "general"
    end
  end

  # Consults sector intelligence to pick the best model for a phase.
  # At low confidence, returns the default. At medium, only overrides if the
  # default model is declining. At high, uses the best available model.
  @doc false
  def pick_model_for_phase(nil, _phase, default_model), do: default_model

  def pick_model_for_phase(sector_id, _phase, default_model) do
    profile = GiTF.Intel.SectorProfile.get_or_compute(sector_id)

    case profile do
      %{confidence: :high, recommendations: %{default_model: rec_model}}
      when is_binary(rec_model) and rec_model != "" ->
        rec_model

      %{confidence: :medium, model_data: model_data} ->
        # At medium confidence, only swap away from a declining model
        default_key = normalize_model_key(default_model)

        case Map.get(model_data, default_key) do
          %{trend: :declining} ->
            # Find a non-declining alternative
            find_non_declining_model(model_data, default_model)

          _ ->
            default_model
        end

      _ ->
        default_model
    end
  rescue
    _ -> default_model
  end

  defp find_non_declining_model(model_data, fallback) do
    model_data
    |> Enum.reject(fn {_model, data} -> data.trend == :declining end)
    |> Enum.filter(fn {_model, data} -> data.total_jobs >= 3 end)
    |> Enum.max_by(fn {_model, data} -> data.success_rate end, fn -> nil end)
    |> case do
      {model, _} -> model
      nil -> fallback
    end
  end

  defp normalize_model_key(model), do: GiTF.Runtime.ModelResolver.normalize_key(model)

  # Reads the op's stored strategy; falls back to a title parse for records
  # written before the `strategy` field existed, and finally to "normal" for
  # ops that have no strategy concept. Prefer `op[:strategy]` for new writes
  # via `spawn_phase_ghost_inner`.
  @doc false
  def op_strategy(op) do
    case op[:strategy] do
      s when is_binary(s) and s != "" ->
        s

      _ ->
        case Regex.run(~r/\[([^\]]+)\]/, op.title || "") do
          [_, strategy] -> strategy
          _ -> "normal"
        end
    end
  end
end
