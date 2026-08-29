defmodule GiTF.Major.DesignBoard do
  @moduledoc """
  THE DESIGN BOARD — the persona that runs the mission's design
  tournament. Up to three ghosts draw competing designs in parallel
  (`minimal`, `normal`, `complex`); the board decides how many to
  commission, waits for the field to go terminal, promotes the winner
  onto the canonical `"design"` artifact, and rules on redesign
  requests.

  It also owns the triage complexity read, because complexity is the
  single input that sizes the tournament: it decides how many strategies
  are worth drawing and (via `ModelPolicy`) which mind draws them.

  What shaped it:

    * Review exists to CROSS-VALIDATE competing proposals. A
      single-variant field has nothing to pick among, so the board
      promotes it directly to planning rather than paying for a review
      ghost to rubber-stamp one design.
    * The field goes to review when every design ghost is TERMINAL, not
      when every one succeeded — a partial field is still a field. Only
      an empty one (all ghosts failed) kills the mission.
    * Promotion never trusts the selection blindly: a review naming a
      variant that produced no artifact falls back to any variant that
      did, then to the legacy single `"design"` key. `GiTF.Phases.Review`
      and `GiTF.Phases.Design` both call in here rather than
      re-deriving that fallback chain.
    * Redesign is budgeted per sector (`max_redesign_for/1`), and when
      the budget runs out the mission PROCEEDS with the current design
      rather than dying — a rejected design is a quality signal, not a
      fatal one.
  """

  require Logger

  alias GiTF.Archive
  alias GiTF.Major.{ModelPolicy, PhaseLauncher}

  @default_max_redesign 2

  @design_strategies [
    %{name: "minimal", hint: "Simplest approach that satisfies the core requirements"},
    %{name: "normal", hint: "Standard implementation following existing patterns"},
    %{name: "complex", hint: "Comprehensive implementation with edge cases and extensibility"}
  ]

  @doc false
  def design_strategies, do: @design_strategies

  # -- Strategy selection ----------------------------------------------------

  @doc false
  def strategies_for_complexity(research, sector_id) do
    complexity = if research, do: Map.get(research, "complexity"), else: nil

    base_count =
      case complexity do
        "moderate" -> 1
        _ -> 3
      end

    # Consult sector intelligence for strategy count adjustment
    count =
      case sector_id && GiTF.Intel.SectorProfile.get_or_compute(sector_id) do
        %{confidence: conf, recommendations: %{strategy_count: rec_count}}
        when conf in [:medium, :high] ->
          GiTF.Intel.SectorProfile.blend(rec_count, base_count, conf)

        _ ->
          base_count
      end

    count = max(1, min(count, 3))

    case count do
      1 -> [Enum.find(@design_strategies, &(&1.name == "normal"))]
      2 -> Enum.filter(@design_strategies, &(&1.name in ["normal", "complex"]))
      _ -> @design_strategies
    end
  end

  # -- The field ---------------------------------------------------------------

  @doc false
  def collect_design_variants(mission_id) do
    @design_strategies
    |> Enum.map(fn %{name: name} ->
      key = "design_#{name}"
      artifact = GiTF.Missions.get_artifact(mission_id, key)
      if artifact, do: {name, artifact}, else: nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
    |> case do
      designs when map_size(designs) > 0 ->
        designs

      _ ->
        # Fallback: check for a single "design" artifact (backward compat)
        case GiTF.Missions.get_artifact(mission_id, "design") do
          nil -> %{}
          design -> %{"normal" => design}
        end
    end
  end

  @doc false
  def check_design_complete(mission) do
    design_ops =
      Archive.filter(:ops, fn j ->
        j.mission_id == mission.id and
          j[:phase_job] == true and
          j[:phase] == "design"
      end)

    if design_ops == [] do
      {:ok, "design"}
    else
      done_ops = Enum.filter(design_ops, &(&1.status == "done"))
      failed_ops = Enum.filter(design_ops, &(&1.status == "failed"))
      total = length(design_ops)
      terminal = length(done_ops) + length(failed_ops)

      if terminal == total do
        # All design ghosts finished — advance to review with all designs
        if done_ops == [] do
          Logger.warning("Quest #{mission.id}: all design ghosts failed")
          GiTF.Major.Orchestrator.fail_quest(mission.id, "All design strategies failed")
        else
          {:ok, mission} = GiTF.Missions.get(mission.id)

          # Review exists to cross-validate multiple design proposals; a
          # single-variant design has nothing to pick among.
          done_variants = Enum.map(done_ops, &ModelPolicy.op_strategy/1) |> Enum.uniq()

          if length(done_variants) <= 1 do
            selected = List.first(done_variants) || "minimal"
            promote_selected_design(mission.id, %{"selected_design" => selected})
            {:ok, mission} = GiTF.Missions.get(mission.id)
            PhaseLauncher.start_planning(mission)
          else
            PhaseLauncher.start_review(mission)
          end
        end
      else
        {:ok, "design"}
      end
    end
  end

  # -- The verdict -------------------------------------------------------------

  @doc """
  Copies the review-selected design variant onto the canonical
  `"design"` artifact key. Public so `GiTF.Phases.Review` can call it
  without duplicating the strategy-fallback logic.
  """
  @spec promote_selected_design(String.t(), map()) :: :ok | {:error, term()}
  def promote_selected_design(mission_id, review) do
    selected = review["selected_design"] || "normal"
    key = "design_#{selected}"

    case GiTF.Missions.get_artifact(mission_id, key) do
      nil ->
        # Fallback: try other variants or existing "design" artifact
        fallback =
          Enum.find_value(@design_strategies, fn %{name: name} ->
            GiTF.Missions.get_artifact(mission_id, "design_#{name}")
          end)

        if fallback, do: GiTF.Missions.store_artifact(mission_id, "design", fallback)

      design ->
        GiTF.Missions.store_artifact(mission_id, "design", design)
    end
  end

  @doc """
  Reject the current designs and trigger a redesign iteration.

  Returns `{:error, :max_redesigns}` if the limit has been reached.
  """
  @spec reject_design(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def reject_design(mission_id, reason) do
    with {:ok, mission} <- GiTF.Missions.get(mission_id),
         :ok <- validate_design_phase(mission) do
      redesign_count = Map.get(mission, :redesign_count, 0)

      if redesign_count < max_redesign_for(mission.sector_id) do
        Archive.update(:missions, mission_id, fn q ->
          q
          |> Map.update(:redesign_count, 1, &(&1 + 1))
          |> Map.put(:redesign_reason, reason)
        end)

        {:ok, mission} = GiTF.Missions.get(mission_id)
        PhaseLauncher.start_design(mission)
      else
        {:error, :max_redesigns}
      end
    end
  end

  @doc false
  def validate_design_phase(mission) do
    if Map.get(mission, :current_phase) in ["design", "review"] do
      :ok
    else
      {:error, :not_in_design_phase}
    end
  end

  @doc """
  Max redesign iterations for `sector_id`, consulting sector
  intelligence at `:high` confidence. Public so `GiTF.Phases.Review`
  can apply the same policy.
  """
  @spec max_redesign_for(String.t() | nil) :: pos_integer()
  def max_redesign_for(nil), do: @default_max_redesign

  def max_redesign_for(sector_id) do
    profile = GiTF.Intel.SectorProfile.get_or_compute(sector_id)

    case profile do
      %{confidence: :high, recommendations: %{max_redesign_iterations: n}} -> n
      _ -> @default_max_redesign
    end
  rescue
    _ -> @default_max_redesign
  end
end
