defmodule GiTF.Skills.Refinement do
  @moduledoc """
  Validator-driven skill refinement, spawned async post-validation.

  On pass: bumps `success_count` on applied skills.
  On fail: bumps `failure_count`, runs a refiner LLM, routes its
  proposal through `Skills.Critic`, and commits if approved AND
  `:skill_auto_commit_enabled` is true.
  """

  require Logger

  alias GiTF.Major.PhaseCollector
  alias GiTF.Skills
  alias GiTF.Skills.Critic
  alias GiTF.Skills.LLM
  alias GiTF.Skills.Telemetry

  @doc """
  Entry point called by the orchestrator post-validation.

  `mission` — the mission struct.
  `validation` — the validation artifact (may include cross_check_override).
  `applied_skill_ids` — IDs of skills installed into any impl ghost worktree.
  """
  @spec refine_after_validation(map(), map(), [String.t()]) :: :ok
  def refine_after_validation(mission, validation, applied_skill_ids)
      when is_list(applied_skill_ids) do
    case overall_verdict(validation) do
      "pass" ->
        handle_pass(mission, applied_skill_ids)

      "fail" ->
        handle_fail(mission, validation, applied_skill_ids)

      other ->
        Logger.debug(
          "Skills.Refinement: unknown verdict #{inspect(other)} on mission #{mission.id}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning(
        "Skills.Refinement for mission #{inspect(Map.get(mission, :id))} raised: " <>
          Exception.message(e)
      )

      :ok
  end

  # -- Pass path ---------------------------------------------------------------

  defp handle_pass(_mission, []), do: :ok

  defp handle_pass(mission, skill_ids) do
    Enum.each(skill_ids, &Skills.bump(&1, :success_count))
    Telemetry.emit_applied_success(skill_ids, mission.id)
    :ok
  end

  # -- Fail path ---------------------------------------------------------------

  defp handle_fail(mission, validation, skill_ids) do
    # Bump failure counters first — stats stay honest even if the refiner
    # LLM call fails downstream.
    Enum.each(skill_ids, &Skills.bump(&1, :failure_count))
    Telemetry.emit_applied_failure(skill_ids, mission.id)

    case run_refiner(mission, validation, skill_ids) do
      {:ok, %{"action" => "no_op"} = proposal} ->
        Telemetry.emit_refiner_no_op(proposal["rationale"])
        :ok

      {:ok, %{"action" => action} = proposal} when action in ["refine_existing", "draft_new"] ->
        maybe_commit(action, proposal, mission)

      {:ok, other} ->
        Logger.warning(
          "Skills.Refinement: refiner returned unexpected shape: #{inspect(other)}"
        )

        :ok

      {:error, reason} ->
        Logger.warning("Skills.Refinement: refiner failed: #{inspect(reason)}")
        :ok
    end
  end

  # -- Refiner LLM call --------------------------------------------------------

  defp run_refiner(mission, validation, skill_ids) do
    applied_skills = Enum.map(skill_ids, &Skills.get/1) |> Enum.reject(&is_nil/1)
    prompt = build_refiner_prompt(mission, validation, applied_skills)

    case LLM.generate_and_extract(refiner_model(), prompt) do
      {:ok, text} -> PhaseCollector.extract_json(text)
      {:error, _} = err -> err
    end
  end

  defp build_refiner_prompt(mission, validation, applied_skills) do
    gaps =
      (validation["gaps"] || [])
      |> Enum.take(10)
      |> Enum.map_join("\n", fn
        g when is_binary(g) -> "- #{g}"
        g when is_map(g) -> "- #{inspect(g)}"
      end)

    cross_check = validation["cross_check_override"]

    override_line =
      if is_binary(cross_check) and cross_check != "",
        do: "\n\nCross-check override reason: #{cross_check}",
        else: ""

    applied_block =
      case applied_skills do
        [] ->
          "(none — no skills were applied to this mission's impl ops)"

        skills ->
          skills
          |> Enum.map_join("\n\n", fn s ->
            "### Skill: #{s.name} (id=#{s.id}, scope=#{s.scope})\n#{s.description}\n\n```\n#{LLM.truncate(s.body, 2000)}\n```"
          end)
      end

    sector_id = Map.get(mission, :sector_id)
    sector_scope_suggestion = if sector_id, do: "or :sector (with sector_id=#{sector_id})", else: ""

    """
    You are maintaining a library of reusable skills for an LLM agent factory.
    A mission failed validation. Your job: propose a skill change (new or
    refined) that, if applied to future missions, would have prevented this
    failure mode.

    Respond with ONLY a single JSON object. No prose, no markdown fences, no
    preamble. The JSON must have this shape:

        {
          "action": "refine_existing" | "draft_new" | "no_op",
          "target_skill_id": <existing skill id or null>,
          "name": <short slug for the new/refined skill or null>,
          "description": <one-sentence description or null>,
          "body": <full markdown body with YAML frontmatter or null>,
          "scope": "global" #{sector_scope_suggestion},
          "rationale": <one-sentence reason for this action>
        }

    Rules:
      - Use "refine_existing" if an applied skill is close but needs
        sharpening. Set target_skill_id.
      - Use "draft_new" if no applied skill covers this failure mode.
      - Use "no_op" if the failure is too specific to generalize into a
        reusable rule (e.g., a one-off bug with no wider pattern).
      - "body" must be a complete Claude-Code-style skill file: a YAML
        frontmatter block (---\\nname:\\ndescription:\\n---) followed by
        markdown content.
      - Prefer global scope unless the lesson is clearly project-specific.

    ## Mission

    Goal: #{Map.get(mission, :goal, "")}#{override_line}

    ## Validation gaps

    #{if gaps == "", do: "(no gaps listed)", else: gaps}

    Verdict: #{validation["overall_verdict"]}

    ## Skills applied to the failed impl ops

    #{applied_block}
    """
  end

  # -- Commit path (critic-gated) ----------------------------------------------

  defp maybe_commit("refine_existing", proposal, mission) do
    target_id = proposal["target_skill_id"]

    case target_id && Skills.get(target_id) do
      nil ->
        Logger.warning(
          "Skills.Refinement: refine_existing target_skill_id=#{inspect(target_id)} not found; treating as draft_new"
        )

        maybe_commit("draft_new", Map.put(proposal, "target_skill_id", nil), mission)

      existing ->
        draft =
          Map.merge(existing, %{
            name: proposal["name"] || existing.name,
            description: proposal["description"] || existing.description,
            body: proposal["body"] || existing.body,
            source: :auto_refined,
            embedding: nil,
            embedding_model: nil
          })

        critic_then_commit(:refine, draft, proposal, mission)
    end
  end

  defp maybe_commit("draft_new", proposal, mission) do
    scope = parse_scope(proposal["scope"])
    sector_id = if scope == :sector, do: Map.get(mission, :sector_id), else: nil

    draft = %{
      name: proposal["name"] || "auto-drafted-#{:erlang.unique_integer([:positive])}",
      description: proposal["description"] || "(no description)",
      body: proposal["body"] || "",
      scope: scope,
      sector_id: sector_id,
      source: :auto_drafted
    }

    critic_then_commit(:draft, draft, proposal, mission)
  end

  defp critic_then_commit(kind, draft, _proposal, mission) do
    if invalid_draft?(draft) do
      Logger.warning(
        "Skills.Refinement: rejecting #{kind} draft — invalid shape: #{inspect(Map.take(draft, [:name, :description, :scope]))}"
      )

      Telemetry.emit_critic_rejected("invalid_shape", kind)
      :ok
    else
      existing_pool =
        case draft do
          %{scope: :sector, sector_id: sid} when is_binary(sid) -> Skills.list_for_sector(sid)
          _ -> Skills.list_global()
        end

      case Critic.review(draft, existing_pool) do
        {:ok, :approve, reason} ->
          if auto_commit_enabled?() do
            commit(kind, draft, mission, reason)
          else
            Logger.info(
              "Skills.Refinement (shadow): critic approved #{kind} but auto_commit is off — draft: #{inspect(draft.name)} / #{reason}"
            )

            :ok
          end

        {:ok, other_verdict, reason} ->
          Logger.info(
            "Skills.Refinement: critic #{other_verdict} for #{kind} — #{reason}"
          )

          Telemetry.emit_critic_rejected(reason, kind)
          :ok

        {:error, reason} ->
          Logger.warning("Skills.Refinement: critic errored (#{inspect(reason)}); treating as reject")
          Telemetry.emit_critic_rejected("critic_error", kind)
          :ok
      end
    end
  end

  defp commit(:refine, draft, _mission, reason) do
    case Skills.update(draft.id, fn _ -> draft end) do
      {:ok, _} ->
        Telemetry.emit_refined(draft.id, draft.scope, reason)
        Logger.info("Skills.Refinement: refined skill #{draft.id} (#{draft.name}) — #{reason}")
        :ok

      {:error, reason} ->
        Logger.warning("Skills.Refinement: refine update failed: #{inspect(reason)}")
        :ok
    end
  end

  defp commit(:draft, draft, _mission, reason) do
    case Skills.create(Map.drop(draft, [:id])) do
      {:ok, created} ->
        Telemetry.emit_drafted(created.id, created.scope, reason)
        Logger.info("Skills.Refinement: drafted skill #{created.id} (#{created.name}) — #{reason}")
        :ok

      {:error, reason} ->
        Logger.warning("Skills.Refinement: draft create failed: #{inspect(reason)}")
        :ok
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp overall_verdict(validation) when is_map(validation) do
    Map.get(validation, "overall_verdict") || Map.get(validation, :overall_verdict) || "unknown"
  end

  defp overall_verdict(_), do: "unknown"

  defp parse_scope("global"), do: :global
  defp parse_scope("sector"), do: :sector
  defp parse_scope(:global), do: :global
  defp parse_scope(:sector), do: :sector
  defp parse_scope(_), do: :global

  defp invalid_draft?(draft) do
    is_nil(draft.body) or draft.body == "" or
      is_nil(draft.name) or draft.name == "" or
      is_nil(draft.description) or draft.description == "" or
      (draft.scope == :sector and is_nil(draft.sector_id))
  end

  defp refiner_model do
    Application.get_env(:gitf, :skill_refinement_model, "google:gemini-2.5-flash")
  end

  defp auto_commit_enabled? do
    Application.get_env(:gitf, :skill_auto_commit_enabled, false)
  end

  # -- Post-completion outcome refinement -------------------------------------

  @doc """
  Called by `GiTF.Outcomes.Tracker` the first time a mission's outcome
  becomes terminal. Mirrors `refine_after_validation/3` but takes the
  real-world signal instead of validator confidence:

    * `:merged_clean` → bump `:success_count` on applied skills.
    * `:merged_reverted`/`:merged_broke_main`/`:closed_unmerged` → bump
      `:failure_count`, run the refiner with real-world failure context
      (revert SHA or reviewer comment body) instead of validator gaps.

  Feature-gated by `:outcome_refinement_enabled`.
  """
  @spec refine_after_merge(map(), map()) :: :ok
  def refine_after_merge(mission, outcome) when is_map(mission) and is_map(outcome) do
    if outcome_refinement_enabled?() do
      skill_ids = applied_skill_ids(mission)
      category = outcome.outcome_category

      cond do
        category == :merged_clean ->
          handle_pass(mission, skill_ids)

        category in GiTF.Outcomes.negative_terminal_categories() ->
          handle_fail(mission, synthetic_validation(outcome, category), skill_ids)

        true ->
          :ok
      end
    else
      :ok
    end
  rescue
    e ->
      Logger.warning(
        "Skills.Refinement.refine_after_merge for mission #{inspect(Map.get(mission, :id))} " <>
          "raised: #{Exception.message(e)}"
      )

      :ok
  end

  # Shapes a terminal outcome as a validation artifact so handle_fail's
  # refiner prompt builder applies unchanged.
  defp synthetic_validation(outcome, category) do
    %{
      "overall_verdict" => "fail",
      "cross_check_override" => "post-merge outcome: #{category}",
      "gaps" => outcome_gaps(outcome, category)
    }
  end

  defp outcome_gaps(outcome, :closed_unmerged) do
    case latest_changes_requested(outcome.reviews || []) do
      nil ->
        ["PR was closed without merging; no reviewer comments recorded."]

      review ->
        body = Map.get(review, :body) || Map.get(review, "body") || ""
        author = Map.get(review, :author) || Map.get(review, "author") || "reviewer"

        [
          "PR closed without merging.",
          "Most recent CHANGES_REQUESTED review (#{author}): #{truncate(body, 2000)}"
        ]
    end
  end

  defp outcome_gaps(_outcome, cat) when cat in [:merged_reverted, :merged_broke_main] do
    ["PR was merged but the change was reverted (#{cat})."]
  end

  defp latest_changes_requested(reviews) do
    reviews
    |> Enum.filter(fn r ->
      (Map.get(r, :state) || Map.get(r, "state")) == "CHANGES_REQUESTED"
    end)
    |> Enum.sort_by(
      fn r -> Map.get(r, :submitted_at) || Map.get(r, "submittedAt") || "" end,
      :desc
    )
    |> List.first()
  end

  defp truncate(nil, _), do: ""

  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max, do: String.slice(str, 0, max) <> "…", else: str
  end

  @doc """
  Extracts applied skill IDs from a mission's ops. Public so callers who
  already have the list (e.g. orchestrator) can match the merge-path
  derivation.
  """
  @spec applied_skill_ids(map()) :: [String.t()]
  def applied_skill_ids(mission) do
    (Map.get(mission, :ops, []) || [])
    |> Enum.flat_map(fn op -> Map.get(op, :applied_skill_ids, []) || [] end)
    |> Enum.uniq()
  end

  defp outcome_refinement_enabled? do
    Application.get_env(:gitf, :outcome_refinement_enabled, false) == true
  end
end
