defmodule GiTF.Phases.Validation do
  @moduledoc """
  Validation phase handler — faithful mirror of
  `GiTF.Validation.handle_result/1`.

  Validation is the most state-dependent phase: pass/fail isn't a simple
  read of `artifact["overall_verdict"]` because legacy applies a
  diff-cross-check, a stale-artifact re-validation pass, a fix-budget
  retry loop (via `Togusa.FixContext`), and a requires-approval routing
  decision. `verdict/2` does all of it via side effects on the artifact
  + the legacy primitives (now exposed as `@doc false def` on
  `Orchestrator`); the YAML stays declarative.

  `verdict/1` (artifact-only) remains the simple `overall_verdict`
  → pass/fail/inconclusive reading used by the generic
  `Workflow.Verdict` path and by operator-authored workflows that only
  want a thin validation handler.

  ## verdict/2 logic, by case

    * `artifact == nil` → `:wait` if a validation op is pending/assigned/
      running (the ghost is simply still working). If NOTHING is in
      flight, the phase is stranded rather than busy, and the verdict
      respawns validation — up to `@max_validation_respawns`, then raises
      a `:mission_stalled` alert and holds. msn-05bebd sat here for hours
      because `nil` meant "wait" unconditionally and the ghost it was
      waiting for had never been spawned.

    * `overall_verdict == "pass"`:
      * Emits `[:gitf, :validation, :passed]` telemetry
        (`emit_validation_confidence/1`).
      * Runs `validate_pass_against_diff/1`. On `:ok`, kicks
        `maybe_spawn_skill_refinement/2` and stamps
        `artifact.requires_approval` (from
        `GiTF.Override.requires_approval?/1`) so the conditional
        `on_pass:` rule routes between `awaiting_approval` and `sync`.
        Returns `:pass`.
      * On cross-check failure, overrides the artifact with
        `overall_verdict="fail"`, a `gaps` entry, and a
        `cross_check_override` reason — matching the legacy "validator
        said pass but no impl commits" override — and recursively
        re-runs the verdict on the overridden artifact (which falls
        into the fail branch). Emits
        `[:gitf, :validation, :pass_overridden]` telemetry.

    * `overall_verdict != "pass"` (fail or overridden):
      * Stale artifact (latest impl op completed after the last
        validation op) → re-spawn a fresh validation ghost via
        `start_validation/1` and return `:wait`. The new ghost's
        artifact drives the next verdict pass.
      * Fix-context exhausted → `:terminal_fail`. `terminal/3` runs
        `maybe_spawn_skill_refinement/2` and `fail_quest` with the
        "Ghost lost in the net" reason.
      * Otherwise → kick `maybe_spawn_skill_refinement/2` and
        `attempt_validation_fixes/3` (spawns a fix-implementation
        ghost), then `:wait`. The next poll cycle sees the validation
        artifact go stale, re-spawns validation, and the loop continues.

  ## The two requirement registers

  `verdict/2` maintains a pair of opposed registers on the mission before
  it judges anything:

    * `accepted_requirements` — the ratchet. Monotonic, fail-open:
      whatever a validator accepted stays accepted, and the next round's
      prompt pins it as SETTLED so the fix budget goes to the open set.
    * `contested_requirements` — the counter-ratchet. Fail-CLOSED:
      whatever a validator rejected stays rejected until someone argues
      it out of that state. `enforce_contested_rebuttals/1` mechanically
      downgrades a `met: true` on a contested id that carries no
      rebuttal, so the flip that shipped msn-978954's FR-5 gap — same
      code, opposite verdict, the concern quietly re-filed as "minor" —
      costs a round instead of nothing.

  Contestation crosses the resume boundary: `GiTF.Missions` seeds a
  resumed child from its whole lineage, so a child cannot un-know what
  its parent found.

  ## Workflow YAML

      - id: validation
        handler: GiTF.Phases.Validation
        on_pass:
          - when: "artifact.requires_approval == true"
            then: awaiting_approval
          - else: sync
        on_fail: validation        # never fires — verdict/2 only returns
        max_retries: 0             # :pass / :wait / :terminal_fail
        on_exhausted: fail

  `on_fail:` is required by the schema even though `verdict/2` never
  returns the `:fail` verdict; the self-loop is unreachable in
  practice.
  """

  @behaviour GiTF.Phase

  require Logger

  alias GiTF.{Major.Orchestrator, Missions, Validation}
  alias GiTF.Togusa.FixContext

  @impl true
  def start(mission, %GiTF.Workflow.Phase{id: id}, _ctx) do
    Orchestrator.dispatch_phase(id, mission)
  end

  # 1-arg verdict — the simple `overall_verdict` reading, kept so the
  # generic `Workflow.Verdict.verdict_for("validation", _)` path and any
  # operator-authored workflow using this handler without the rich
  # legacy machinery still works.
  @impl true
  def verdict(artifact) when is_map(artifact) do
    case verdict_field(artifact) do
      v when v in ["pass", "passed"] -> :pass
      v when v in ["fail", "failed"] -> :fail
      _ -> :inconclusive
    end
  end

  def verdict(_), do: :inconclusive

  # 2-arg verdict — the full faithful port of handle_validation_result/1.
  # Tournament mode (mission.impl_variants != []) short-circuits ahead of
  # the single-variant artifact-driven path: each variant has its own
  # `validation_<id>` artifact, and the verdict is driven by
  # `GiTF.Tournament` instead of a single `validation` key.
  @impl true
  def verdict(mission, _artifact) when is_map(mission) do
    # Order is load-bearing. The rebuttal gate runs FIRST because the
    # ratchet is monotonic: once it banks a `met: true`, no later pass can
    # take it back, so an unrebutted flip that reaches the ratchet is
    # settled forever. Contested recording runs after the ratchet so an
    # id the ratchet just accepted drops out of the contested set in the
    # same pass rather than being quoted at the next round as still open.
    mission =
      mission
      |> enforce_contested_rebuttals()
      |> record_accepted_requirements()
      |> record_contested_requirements()
      |> clear_respawns_if_validated()

    cond do
      # Tournament already resolved — winner_variant stamped; stay on the
      # single-variant path so subsequent polls don't re-run the
      # tournament.
      is_binary(Map.get(mission, :winning_variant)) ->
        verdict_single(mission, Missions.get_artifact(mission.id, "validation"))

      (Map.get(mission, :impl_variants) || []) != [] ->
        verdict_tournament(mission)

      true ->
        verdict_single(mission, Missions.get_artifact(mission.id, "validation"))
    end
  end

  defp verdict_tournament(mission) do
    case GiTF.Tournament.resolve(mission) do
      {:ok, winning_variant} ->
        promote_winning_variant(mission, winning_variant)

      {:error, :not_ready} ->
        :wait

      {:error, :all_disqualified} ->
        Logger.warning(
          "Quest #{mission.id}: all #{length(mission.impl_variants)} variants disqualified"
        )

        :terminal_fail

      # impl_variants was populated when the dispatcher checked but
      # came back empty here (race against an Archive update). Wait
      # and retry.
      {:error, :no_variants} ->
        :wait
    end
  end

  defp promote_winning_variant(mission, winning_variant) do
    winner_artifact =
      Missions.get_artifact(mission.id, GiTF.Tournament.validation_key(winning_variant)) || %{}

    # Store the artifact BEFORE stamping `winning_variant` so the
    # tournament short-circuit at verdict/2 (which keys off
    # winning_variant) never sees a stamp without a canonical artifact
    # to consume. A crash between the two writes would leave the next
    # poll re-running this path and producing the same result.
    Missions.store_artifact(mission.id, "validation", winner_artifact)

    GiTF.Archive.update(:missions, mission.id, fn record ->
      Map.put(record, :winning_variant, winning_variant)
    end)

    Logger.info(
      "Quest #{mission.id}: tournament winner = #{winning_variant} " <>
        "(score breakdown via GiTF.Tournament.rank/1)"
    )

    GiTF.Telemetry.emit([:gitf, :validation, :tournament_winner], %{}, %{
      mission_id: mission.id,
      winner: winning_variant,
      variant_count: length(mission.impl_variants)
    })

    # Fall through to the single-variant verdict path on the now-canonical
    # validation artifact. Update the in-memory mission with the stamp;
    # reloading via Missions.get would clobber `mission.ops` for tests
    # that hand-build them on the record.
    verdict_single(Map.put(mission, :winning_variant, winning_variant), winner_artifact)
  end

  # No validation artifact. Normally that just means the ghost is still
  # working — but on msn-05bebd the ghost was never born (the exec
  # validation aborted the spawn after the phase had already transitioned)
  # and this clause answered `:wait` to the Janitor every three minutes,
  # forever, with nothing in flight to wait FOR.
  defp verdict_single(mission, nil), do: heal_or_wait(mission)

  defp verdict_single(mission, %{"overall_verdict" => "pass"} = artifact) do
    # Idempotent fast-path: this branch fires on every poll while
    # current_phase = "validation" and the artifact says pass; if we've
    # already done the side effects (artifact already carries
    # `requires_approval`), short-circuit so we don't re-emit telemetry,
    # re-run the cross-check, or re-write the artifact every tick.
    if Map.has_key?(artifact, "requires_approval") do
      :pass
    else
      validate_pass(mission, artifact)
    end
  end

  defp verdict_single(mission, artifact) when is_map(artifact) do
    # Cheap staleness check first — if the latest impl op finished after
    # the validation we're looking at, the artifact is moot regardless of
    # the fix budget. Skip the (heavier) fix-context load in that case.
    latest_impl = Validation.latest_completed_impl_op(mission)

    if Validation.artifact_stale?(latest_impl, artifact, mission) do
      Logger.info(
        "Quest #{mission.id}: validation artifact is stale (fix completed after), re-validating"
      )

      Orchestrator.dispatch_phase("validation", mission)
      :wait
    else
      handle_validation_fail(mission, artifact)
    end
  end

  defp verdict_single(_mission, _artifact), do: :wait

  # -- Self-heal: a validation phase with nobody working on it ----------------

  # Three respawns, then stop and shout. The bound matters more than the
  # number: an unbounded self-heal against a genuinely un-spawnable
  # validation is just the same wedge with a token bill attached.
  @max_validation_respawns 3

  defp heal_or_wait(mission) do
    cond do
      Map.get(mission, :current_phase) != "validation" ->
        :wait

      # Someone IS coming — this is the ordinary "ghost still working" case.
      GiTF.Major.PhaseLauncher.validation_in_flight?(mission.id) ->
        :wait

      true ->
        respawn_validation(mission)
    end
  end

  defp respawn_validation(mission) do
    attempts = Map.get(mission, :validation_respawns) || 0

    if attempts >= @max_validation_respawns do
      hold_stalled_validation(mission, attempts)
    else
      Logger.warning(
        "Quest #{mission.id}: phase is validation with no artifact and no validation op " <>
          "in flight — respawning validation (#{attempts + 1}/#{@max_validation_respawns})"
      )

      GiTF.Archive.update(:missions, mission.id, fn m ->
        Map.put(m, :validation_respawns, attempts + 1)
      end)

      GiTF.Telemetry.emit([:gitf, :validation, :respawned], %{attempt: attempts + 1}, %{
        mission_id: mission.id
      })

      # The counter is incremented BEFORE the attempt, and the attempt
      # itself is isolated: the whole point of this path is that the
      # validation start can die, and a self-heal that dies with it would
      # take the Janitor's advance down instead of the mission's wedge.
      try do
        GiTF.Major.PhaseLauncher.start_validation(mission)
      rescue
        e ->
          Logger.error("Quest #{mission.id}: validation respawn failed: #{Exception.message(e)}")
      catch
        kind, reason ->
          Logger.error("Quest #{mission.id}: validation respawn #{kind}ed: #{inspect(reason)}")
      end

      :wait
    end
  end

  # Deliberately still `:wait`, not `:terminal_fail`: the tree is intact
  # and the mission is recoverable by hand, so a human decides. What
  # changes is that the operator is now told, instead of the Janitor
  # advancing a silent mission every three minutes.
  defp hold_stalled_validation(mission, attempts) do
    Logger.error(
      "Quest #{mission.id}: validation could not be spawned after #{attempts} attempts — holding"
    )

    GiTF.Observability.Alerts.dispatch_webhook(
      :mission_stalled,
      "Quest #{mission.id}: phase is validation but no validation ghost exists and " <>
        "#{attempts} respawn attempts failed. The mission is HELD — inspect the sector's " <>
        "toolchain and re-dispatch by hand.",
      dedup_key: "validation_unspawnable:#{mission.id}"
    )

    :wait
  end

  # -- The ratchet: requirements a validator already accepted -----------------

  @doc """
  Merges every `met: true` requirement id from the mission's validation
  artifacts into `mission.accepted_requirements`, returning the mission
  with the field up to date.

  A fix round costs a full validation pass, and the last two runs spent
  theirs re-proving requirements an earlier round had already accepted —
  hitting the fix cap with one real gap outstanding. Persisting the
  accepted set lets the next round's prompt pin them as settled
  (`PhasePrompts` renders them as ACCEPTED) so the budget goes to the open
  set. Monotonic on purpose: a requirement is never un-accepted by a later
  round that simply did not look at it.
  """
  @spec record_accepted_requirements(map()) :: map()
  def record_accepted_requirements(mission) do
    previous = Map.get(mission, :accepted_requirements) || []
    merged = Enum.uniq(previous ++ accepted_in_artifacts(mission))

    if merged == previous do
      mission
    else
      GiTF.Archive.update(:missions, mission.id, &Map.put(&1, :accepted_requirements, merged))
      Map.put(mission, :accepted_requirements, merged)
    end
  end

  # Every `validation` / `validation_<variant>` artifact, so a tournament's
  # losing variants still contribute what they proved.
  defp accepted_in_artifacts(mission) do
    mission
    |> validation_artifacts()
    |> Enum.flat_map(&met_requirement_ids/1)
  end

  defp validation_artifacts(mission) do
    mission |> validation_artifact_pairs() |> Enum.map(fn {_key, artifact} -> artifact end)
  end

  # The same set with the storage key attached, for the callers that must
  # write an artifact back rather than only read it. Sorted so a
  # tournament's variants are visited in a stable order — the contested
  # merge is last-writer-wins, and "last" must not depend on map layout.
  defp validation_artifact_pairs(mission) do
    (Map.get(mission, :artifacts) || %{})
    |> Enum.filter(fn {key, value} ->
      is_binary(key) and String.starts_with?(key, "validation") and is_map(value)
    end)
    |> Enum.sort_by(fn {key, _artifact} -> key end)
  end

  # A validator DID report on this mission, so the "nobody is coming"
  # budget is spent and starts fresh for any later stall.
  defp clear_respawns_if_validated(mission) do
    if Map.get(mission, :validation_respawns, 0) > 0 and validation_artifacts(mission) != [] do
      GiTF.Archive.update(:missions, mission.id, &Map.put(&1, :validation_respawns, 0))
      Map.put(mission, :validation_respawns, 0)
    else
      mission
    end
  end

  defp met_requirement_ids(%{"requirements_met" => entries}) when is_list(entries) do
    for %{"met" => true} = entry <- entries,
        id = entry["req_id"] || entry["id"],
        is_binary(id) and id != "",
        do: id
  end

  defp met_requirement_ids(_), do: []

  # -- The counter-ratchet: requirements a validator already REJECTED ---------

  # Below this, a "rebuttal" is not an argument. The floor is crude on
  # purpose — it cannot judge whether the reasoning is sound, only that
  # reasoning was offered. "fixed", "now works", "see the diff" are
  # precisely what an amnesiac flip looks like, and all three fit in a
  # dozen characters.
  @rebuttal_min_chars 40

  @doc false
  @spec rebuttal_min_chars() :: pos_integer()
  def rebuttal_min_chars, do: @rebuttal_min_chars

  # What a contested entry says when no validator ever articulated why.
  @default_contested_reason "previously judged unmet"

  @doc """
  Downgrades every `met: true` verdict on an OPEN contested requirement
  that arrives without a rebuttal, rewriting the offending artifact in
  place and failing its round.

  msn-978954 is the whole argument. Its parent (msn-398fa4) judged FR-5
  unmet with a specific reason; the resumed child's validator looked at
  byte-identical code and called it met — while filing the very same
  concern in `gaps` as "minor, non-blocking". Nothing in the pipeline
  ever made it confront the earlier verdict, so the flip cost nothing
  and the mission shipped the gap. A verdict that can move without the
  code moving is not a verdict.

  This is the fail-closed twin of `record_accepted_requirements/1`. The
  ratchet banks agreement; this gate prices disagreement. Flipping a
  contested requirement is still permitted — it must merely be argued:
  a `rebuttal` of at least `#{@rebuttal_min_chars}` characters naming
  what in the current tree answers the quoted reason, or why the prior
  verdict was wrong. Anything less is rewritten to `met: false` and the
  artifact's verdict to `fail`, which routes the round back into the fix
  loop instead of into approval.

  Two artifacts are left alone:

    * one already carrying `requires_approval` — `validate_pass/2` has
      run, the mission has moved, and rewriting a verdict that has
      already been acted on would only desynchronise the record from
      what happened;
    * one with nothing to downgrade, which is also what makes this
      idempotent: the rewrite itself clears the condition it matches on,
      so the next poll finds no violation.

  The mission comes back with the rewritten artifacts patched into its
  in-memory `:artifacts` as well as stored. That is not cosmetic —
  `record_accepted_requirements/1` reads the in-memory map, and a stale
  copy would let it bank the very flip this gate just rejected.
  """
  @spec enforce_contested_rebuttals(map()) :: map()
  def enforce_contested_rebuttals(mission) do
    open = open_contested(mission)

    if open == %{} do
      mission
    else
      mission
      |> validation_artifact_pairs()
      |> Enum.reduce(mission, fn {key, artifact}, acc ->
        enforce_in_artifact(acc, key, artifact, open)
      end)
    end
  end

  # Contested minus accepted. Enforcement is the only door through which
  # a contested id reaches `accepted_requirements`, so an id on both
  # lists was rebutted at some point and is settled.
  defp open_contested(mission) do
    accepted = MapSet.new(Map.get(mission, :accepted_requirements) || [])

    for entry <- Map.get(mission, :contested_requirements) || [],
        is_map(entry),
        id = entry["req_id"],
        is_binary(id) and id != "",
        not MapSet.member?(accepted, id),
        into: %{},
        do: {id, contested_reason(entry)}
  end

  defp enforce_in_artifact(mission, key, artifact, open) do
    if Map.has_key?(artifact, "requires_approval") do
      mission
    else
      case unrebutted_ids(artifact, open) do
        [] -> mission
        ids -> downgrade_unrebutted(mission, key, artifact, ids, open)
      end
    end
  end

  defp unrebutted_ids(%{"requirements_met" => entries}, open) when is_list(entries) do
    for entry <- entries,
        is_map(entry),
        entry["met"] == true,
        id = entry["req_id"] || entry["id"],
        is_binary(id),
        Map.has_key?(open, id),
        not rebutted?(entry),
        do: id
  end

  defp unrebutted_ids(_artifact, _open), do: []

  defp rebutted?(entry) do
    case entry["rebuttal"] do
      text when is_binary(text) -> String.length(String.trim(text)) >= @rebuttal_min_chars
      _ -> false
    end
  end

  defp downgrade_unrebutted(mission, key, artifact, ids, open) do
    flagged = MapSet.new(ids)

    entries =
      Enum.map(artifact["requirements_met"], fn entry ->
        if is_map(entry) and MapSet.member?(flagged, entry["req_id"] || entry["id"]) do
          # The original evidence stays: it is the case the validator
          # made, and a post-mortem needs to read it next to the verdict
          # that rejected it.
          entry |> Map.put("met", false) |> Map.put("rebuttal_missing", true)
        else
          entry
        end
      end)

    rewritten =
      artifact
      |> Map.put("requirements_met", entries)
      |> Map.put("gaps", existing_gaps(artifact) ++ Enum.map(ids, &downgrade_gap(&1, open[&1])))
      |> Map.put("overall_verdict", "fail")

    Missions.store_artifact(mission.id, key, rewritten)

    Logger.warning(
      "Quest #{mission.id}: contested-rebuttal gate downgraded #{Enum.join(ids, ", ")} " <>
        "in artifact #{key} — marked met over a standing UNMET verdict with no rebuttal"
    )

    GiTF.Telemetry.emit([:gitf, :validation, :contested_downgraded], %{count: length(ids)}, %{
      mission_id: mission.id,
      req_ids: ids
    })

    Map.put(mission, :artifacts, Map.put(Map.get(mission, :artifacts) || %{}, key, rewritten))
  end

  defp existing_gaps(artifact) do
    case artifact["gaps"] do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp downgrade_gap(id, reason) do
    "#{id} was previously judged UNMET (#{reason || @default_contested_reason}). " <>
      "This round marked it met without a rebuttal addressing that verdict — " <>
      "downgraded to unmet. Fix the code, or flip it with an explicit rebuttal " <>
      "citing what in the current tree answers the quoted reason."
  end

  @doc """
  Merges every `met: false` requirement id from the mission's validation
  artifacts into `mission.contested_requirements`, as
  `%{"req_id" => id, "reason" => text}`.

  The mirror of the ratchet, and deliberately NOT monotonic in the same
  direction: an id leaves the contested set the moment it lands in
  `accepted_requirements`, because `enforce_contested_rebuttals/1` is the
  only path by which it can get there. The reason is last-writer-wins —
  the freshest articulation of what is wrong is the one worth quoting at
  the next round.

  A downgraded entry (`rebuttal_missing`) contributes its id but no
  reason. Its evidence argues that the requirement was met; it is the
  text the gate has just rejected, and letting it become the contested
  reason would replace the standing verdict with the flip's own case for
  itself.
  """
  @spec record_contested_requirements(map()) :: map()
  def record_contested_requirements(mission) do
    previous = Map.get(mission, :contested_requirements) || []
    accepted = MapSet.new(Map.get(mission, :accepted_requirements) || [])

    merged =
      previous
      |> normalize_contested()
      |> merge_contested(unmet_in_artifacts(mission))
      |> Enum.reject(fn %{"req_id" => id} -> MapSet.member?(accepted, id) end)

    if merged == previous do
      mission
    else
      GiTF.Archive.update(:missions, mission.id, &Map.put(&1, :contested_requirements, merged))
      Map.put(mission, :contested_requirements, merged)
    end
  end

  # Existing order is preserved and new ids append, so the merge converges
  # to a fixed point after one write instead of churning the record on
  # every poll.
  defp merge_contested(previous, fresh) do
    reasons =
      Enum.reduce(fresh, Map.new(previous, &{&1["req_id"], &1["reason"]}), fn
        {id, nil}, acc -> Map.put_new(acc, id, @default_contested_reason)
        {id, reason}, acc -> Map.put(acc, id, reason)
      end)

    (Enum.map(previous, & &1["req_id"]) ++ Enum.map(fresh, &elem(&1, 0)))
    |> Enum.uniq()
    |> Enum.map(&%{"req_id" => &1, "reason" => Map.fetch!(reasons, &1)})
  end

  defp normalize_contested(entries) when is_list(entries) do
    for entry <- entries,
        is_map(entry),
        id = entry["req_id"],
        is_binary(id) and id != "",
        do: %{"req_id" => id, "reason" => contested_reason(entry)}
  end

  defp normalize_contested(_), do: []

  defp contested_reason(entry) do
    case entry["reason"] do
      text when is_binary(text) ->
        case String.trim(text) do
          "" -> @default_contested_reason
          trimmed -> trimmed
        end

      _ ->
        @default_contested_reason
    end
  end

  defp unmet_in_artifacts(mission) do
    mission
    |> validation_artifacts()
    |> Enum.flat_map(&unmet_requirements/1)
  end

  defp unmet_requirements(%{"requirements_met" => entries}) when is_list(entries) do
    for entry <- entries,
        is_map(entry),
        entry["met"] == false,
        id = entry["req_id"] || entry["id"],
        is_binary(id) and id != "",
        do: {id, unmet_reason(entry)}
  end

  defp unmet_requirements(_), do: []

  defp unmet_reason(%{"rebuttal_missing" => true}), do: nil

  defp unmet_reason(entry) do
    case entry["evidence"] do
      text when is_binary(text) ->
        case String.trim(text) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp validate_pass(mission, artifact) do
    Validation.emit_confidence(mission)

    # Two gates, both fail-safe overrides of a "pass" verdict: (1) the diff
    # cross-check (real commits exist), then (2) behavioral verification
    # (holdout scenarios driven through the artifact's real interface). Either
    # failing routes back into the fix loop rather than merging.
    with :ok <- Validation.validate_pass_against_diff(mission),
         :ok <- Validation.verify_behavior(mission) do
      Validation.maybe_spawn_skill_refinement(mission, artifact)

      requires_approval = GiTF.Override.requires_approval?(mission)

      Missions.store_artifact(
        mission.id,
        "validation",
        Map.put(artifact, "requires_approval", requires_approval)
      )

      :pass
    else
      {:error, reason} ->
        Logger.warning(
          "Quest #{mission.id}: validator said PASS but a gate overrode it (#{reason}); " <>
            "treating as fail and re-routing to fix loop"
        )

        GiTF.Telemetry.emit([:gitf, :validation, :pass_overridden], %{}, %{
          mission_id: mission.id,
          reason: reason
        })

        overridden =
          artifact
          |> Map.put("overall_verdict", "fail")
          |> Map.put("gaps", ["Validator returned pass but a gate overrode it: #{reason}"])
          |> Map.put("cross_check_override", reason)

        Missions.store_artifact(mission.id, "validation", overridden)
        # Stay on the single-variant path; otherwise we'd re-enter
        # verdict_tournament which would re-pick the same winner and
        # loop indefinitely.
        verdict_single(mission, overridden)
    end
  end

  # Hard ceiling on TOTAL fix ops per mission (any lane, any status), as a
  # multiple of the validation fix budget. The per-context attempt counter
  # can be gamed by lane dynamics: on run 17 deferred validation attempts
  # never recorded (counter frozen at 3/4) while the quality gate minted
  # fresh attempt-1 fixes against each new fix op as origin — the mission
  # churned "attempt 4/4" every 3 minutes indefinitely. Total-op count is
  # ungameable.
  @max_total_fix_ops_factor 3

  defp handle_validation_fail(mission, artifact) do
    fix_ctx = Validation.load_fix_context(mission)

    total_fix_ops =
      Enum.count(mission.ops, fn op ->
        op[:phase_job] not in [true] and is_binary(op[:fix_of])
      end)

    hard_cap = fix_ctx.max_attempts * @max_total_fix_ops_factor

    cond do
      infrastructure_failure?(artifact) or exec_infra_failure?(mission) ->
        # The tree was never judged: the toolchain was missing, the disk was
        # full, a probe lock starved. Spending a fix attempt sends a ghost
        # to "fix" code that was never found wanting, and it returns empty —
        # which is how runs 27-29 ground to their ceilings with healthy
        # trees. Wait for the next validation pass instead; the attempt
        # counter stays intact for real findings.
        Logger.warning(
          "Quest #{mission.id} validation hit an INFRASTRUCTURE failure — " <>
            "re-validating without burning a fix attempt (#{fix_ctx.attempt}/#{fix_ctx.max_attempts} intact)"
        )

        GiTF.Observability.Alerts.dispatch_webhook(
          :validation_infra_failure,
          "Quest #{mission.id}: validation infrastructure failure (toolchain/probe) — " <>
            "fix attempts held at #{fix_ctx.attempt}/#{fix_ctx.max_attempts}, re-validating"
        )

        :wait

      FixContext.exhausted?(fix_ctx) ->
        Logger.warning(
          "Quest #{mission.id} validation failed after #{fix_ctx.attempt} fix attempts — ghost lost in the net"
        )

        :terminal_fail

      total_fix_ops >= hard_cap ->
        Logger.warning(
          "Quest #{mission.id} validation failed with #{total_fix_ops} total fix ops " <>
            "(hard cap #{hard_cap}) — sealing regardless of attempt counter"
        )

        :terminal_fail

      true ->
        Logger.info(
          "Quest #{mission.id} validation failed (attempt #{fix_ctx.attempt + 1}/#{fix_ctx.max_attempts})"
        )

        Validation.maybe_spawn_skill_refinement(mission, artifact)
        Validation.attempt_fixes(mission, artifact, fix_ctx)
        :wait
    end
  end

  # The exec-validation layer already classifies host problems (missing
  # toolchain, exhausted disk, an unavailable probe lock) as TOOL MISSING /
  # exit 127 rather than blaming the diff. Anything carrying that marker
  # means the ghost's code was never actually evaluated.
  @doc false
  @spec infrastructure_failure?(map() | nil) :: boolean()
  def infrastructure_failure?(artifact) when is_map(artifact) do
    gaps =
      case artifact["gaps"] do
        list when is_list(list) -> Enum.filter(list, &is_binary/1)
        _ -> []
      end

    text =
      ([
         artifact["exec_validation_output"],
         artifact["summary"],
         get_in(artifact, ["failures", "output"])
       ] ++ gaps)
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(text, "tool missing on host") or
      String.contains?(text, "infrastructure problem, not a code problem")
  end

  def infrastructure_failure?(_), do: false

  # The factory's own out-of-band verdict, written by run_exec_validation
  # every round. This is the authoritative signal — the string sniffing
  # above is only a fallback for artifacts produced before the verdict
  # existed. Run 7 (msn-4fda11) burned 4 fix attempts because the LLM
  # validator paraphrased the sentinel out of its summary and the guard
  # relied on prose.
  @doc false
  @spec exec_infra_failure?(map()) :: boolean()
  def exec_infra_failure?(mission) when is_map(mission) do
    case get_in(mission, [Access.key(:artifacts, %{}), "exec_validation"]) do
      %{"status" => "fail", "infra_failure" => true} -> true
      _ -> false
    end
  end

  def exec_infra_failure?(_), do: false

  @impl true
  def terminal(mission, :retries_exhausted, artifact) do
    if is_map(artifact),
      do: Validation.maybe_spawn_skill_refinement(mission, artifact)

    fix_ctx = Validation.load_fix_context(mission)

    Missions.fail_quest(
      mission.id,
      "Ghost lost in the net — validation failed after #{fix_ctx.attempt} attempts"
    )

    :ok
  end

  def terminal(_mission, _kind, _artifact), do: :ok

  @doc false
  @spec verdict_field(map()) :: String.t()
  def verdict_field(artifact) when is_map(artifact) do
    artifact["overall_verdict"] || artifact[:overall_verdict] ||
      artifact["verdict"] || artifact[:verdict] ||
      get_in(artifact, ["overall", "verdict"]) || ""
  end
end
