defmodule GiTF.Inquiry.Gate do
  @moduledoc """
  THE SEAM — where a phase's question becomes a held mission, and where
  an answered question becomes a re-dispatched phase.

  ## Why the seam is an artifact key

  A phase ghost's only structured output is its artifact. It has no
  other channel to the orchestrator: no verdict vocabulary of its own,
  no side band, nothing the `PhaseCollector` does not parse out of the
  JSON block. So a phase asks by emitting a `questions` list in the
  artifact it was already going to write, and this module turns that
  list into records on the way through `advance_quest/1`.

  Every alternative was worse. A dedicated link_msg type would need the
  ghost to be alive when the operator answers. A new verdict atom would
  only reach workflow-driven missions, and the workflow layer is
  default-off. A tool call would put the gate behind the sandbox policy.
  The artifact is the one path every phase already has.

  ## Why the interception is above the workflow/legacy fork

  `intercept/1` runs in `Orchestrator.advance_mission_phase/1` BEFORE
  the mission is handed to either `WorkflowBridge.advance_via_workflow/2`
  or `advance_via_legacy/2`, and the held state is handled there too.
  That placement is load-bearing, not tidiness:

    * `awaiting_input` is not a step in anyone's pipeline — ANY phase
      can raise it. A workflow YAML that does not declare the phase
      would hit `GiTF.Workflow.Advancer`'s WORKFLOW DRIFT path, which
      HOLDS the mission and pages the operator. Every workflow in
      `priv/workflows` would have had to declare a phase it never routes
      to, and every operator-authored one would strand its missions.
    * The gate has to work identically on both dispatch paths, because
      the same question can be raised by the same phase either way.

  ## Why the artifact is moved aside

  When a phase holds, its artifact is renamed `<key>_asked` and the
  canonical key is REMOVED. Without that, `check_and_advance/3` sees a
  present, non-failed artifact the instant the mission returns and walks
  straight on to the next phase — the operator's answer would be
  recorded, and nothing would ever be built with it. The artifact is
  moved rather than deleted because it is still the best record of what
  the phase was thinking when it asked.

  ## Why this cannot loop

  The asking phase is re-dispatched, so it runs again, so it can ask
  again. Three things stop that being a cycle:

    1. `Inquiry.ask/2` is idempotent on `{phase, key}` and returns the
       standing ANSWER rather than opening a second question.
    2. `Inquiry.prompt_block/1` puts the answer in the re-dispatched
       phase's prompt (via `Intel.get_prompt_context/3`), so a compliant
       ghost has no reason to ask.
    3. The per-mission budget refuses the fourth question outright.

  Only the first is a guarantee. The other two are why the first rarely
  has to fire.
  """

  require Logger

  alias GiTF.Inquiry.Preview
  alias GiTF.{Archive, Inquiry, Missions, Observability}

  @gate_phase "awaiting_input"

  @doc """
  Looks at the artifacts the mission's current phase has written and, if
  any of them raised questions, holds the mission.

  Returns `{:held, phase}` when the mission is now at `awaiting_input`
  and the caller must stop advancing it, or `:clear` when there is
  nothing to hold for — which is the answer on the overwhelming majority
  of advances, and is therefore the cheap path: one artifact-map scan,
  no store writes.

  Never raises. An advance loop that can be taken down by a malformed
  `questions` value would be a worse bug than the one this closes.
  """
  @spec intercept(map()) :: {:held, String.t()} | :clear
  def intercept(mission) when is_map(mission) do
    phase = Map.get(mission, :current_phase)

    if holdable_phase?(phase) do
      case questioning_artifacts(mission, phase) do
        [] -> :clear
        pairs -> raise_all(mission, phase, pairs)
      end
    else
      :clear
    end
  rescue
    e ->
      Logger.warning(
        "Quest #{Map.get(mission, :id)}: input-gate interception failed " <>
          "(#{Exception.message(e)}) — advancing without holding"
      )

      :clear
  end

  def intercept(_), do: :clear

  # Which phases may ask is `Inquiry.askable_phase?/1`'s call, not this
  # module's — the same predicate gates the invitation in the prompt, so a
  # phase cannot be invited to ask something the interception would ignore.
  defp holdable_phase?(phase), do: Inquiry.askable_phase?(phase)

  # Parallel phases write suffixed keys ("design_minimal", "validation_v2").
  # Same prefix rule as `Missions.inheritable?/2`, so a tournament variant
  # can ask as readily as a single-strategy phase.
  defp questioning_artifacts(mission, phase) do
    (Map.get(mission, :artifacts) || %{})
    |> Enum.filter(fn {key, artifact} ->
      is_binary(key) and family?(key, phase) and is_map(artifact) and
        questions_of(artifact) != []
    end)
    |> Enum.sort_by(fn {key, _} -> key end)
  end

  defp family?(key, phase), do: key == phase or String.starts_with?(key, phase <> "_")

  defp questions_of(artifact) do
    case Map.get(artifact, "questions") || Map.get(artifact, :questions) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp raise_all(mission, phase, pairs) do
    results =
      for {key, artifact} <- pairs,
          question <- questions_of(artifact),
          do: {key, ask_one(mission, phase, key, question)}

    held = for {_key, {:held, inquiry}} <- results, do: inquiry
    rejected = for {key, {:rejected, reason}} <- results, do: {key, reason}

    Enum.each(rejected, fn {key, reason} -> note_rejection(mission, key, reason) end)

    if held == [] do
      :clear
    else
      Enum.each(pairs, fn {key, artifact} -> move_aside(mission, key, artifact) end)
      hold(mission, phase, held)
    end
  end

  # Validate, then RENDER, then record.
  #
  # `Inquiry.ask/2` validates again on the way in, so the first call here
  # is not the enforcement — it is the ordering. Validation is pure and
  # costs nothing, and there is no reason to spawn a headless browser for
  # a question that is about to be refused as unanswerable. Rendering has
  # to happen at this exact seam and nowhere later: the mockup lives in
  # the asking ghost's worktree, and worktrees are reaped on completion
  # and swept when they go orphan, so this is the last moment the source
  # is guaranteed to exist. `Preview.attach/3` copies it out.
  #
  # `attach/3` cannot fail. Every unrenderable option comes back with its
  # label, its rationale and a note saying why there is no picture, so a
  # broken mockup costs the operator some context and never the question.
  defp ask_one(mission, phase, key, question) when is_map(question) do
    attrs = Map.merge(question, %{phase: phase, asked_by: "phase:#{phase}"})

    case Inquiry.validate(attrs) do
      {:ok, validated} ->
        # The artifact key names WHICH variant asked (design_minimal), and
        # therefore which worktree holds the mockups.
        record(mission, phase, Preview.attach(mission, phase, validated, key))

      {:error, {:invalid, reason}} ->
        {:rejected, reason}
    end
  end

  defp ask_one(_mission, _phase, _key, other),
    do: {:rejected, "a question must be a map, got #{inspect(other, limit: 5)}"}

  defp record(mission, phase, attrs) do
    case Inquiry.ask(mission.id, attrs) do
      {:ok, inquiry, tag} when tag in [:asked, :open] ->
        {:held, inquiry}

      {:ok, inquiry, :already_answered} ->
        Logger.info(
          "Quest #{mission.id}: #{phase} re-asked #{inquiry.key}, which is already answered " <>
            "(#{inquiry[:answer_label] || inquiry[:answer]}) — not holding"
        )

        {:answered, inquiry}

      {:error, {:budget_exhausted, budget}} ->
        {:rejected, "inquiry budget of #{budget} already spent on this mission"}

      {:error, {:invalid, reason}} ->
        {:rejected, reason}

      {:error, other} ->
        {:rejected, inspect(other, limit: 10)}
    end
  end

  # A question nobody could answer must not become a mission nobody can
  # unstick. The refusal is written onto the artifact so it shows up in
  # `show_artifact` and the mission page, and alerted so the operator
  # learns their phase prompt is emitting malformed questions — the
  # phase then proceeds on its own judgement, which is exactly what it
  # would have done had it never asked.
  defp note_rejection(mission, key, reason) do
    Logger.warning(
      "Quest #{mission.id}: #{key} raised an unanswerable question (#{reason}) — refused, " <>
        "the phase proceeds without holding"
    )

    Archive.update(:missions, mission.id, fn record ->
      artifacts = Map.get(record, :artifacts) || %{}

      case Map.get(artifacts, key) do
        artifact when is_map(artifact) ->
          rejections = Map.get(artifact, "questions_rejected", [])
          updated = Map.put(artifact, "questions_rejected", rejections ++ [reason])
          Map.put(record, :artifacts, Map.put(artifacts, key, updated))

        _ ->
          record
      end
    end)

    Observability.Alerts.dispatch_webhook(
      :input_question_rejected,
      "Quest #{mission.id}: #{key} emitted a question that cannot be answered (#{reason}). " <>
        "The phase continued on its own judgement.",
      dedup_key: "input_question_rejected:#{mission.id}:#{key}"
    )
  rescue
    _ -> :ok
  end

  defp move_aside(mission, key, artifact) do
    Archive.update(:missions, mission.id, fn record ->
      artifacts = Map.get(record, :artifacts) || %{}

      updated =
        artifacts
        |> Map.delete(key)
        |> Map.put(key <> "_asked", Map.put(artifact, "held_for_input_at", now_iso()))

      Map.put(record, :artifacts, updated)
    end)
  end

  defp hold(mission, phase, held) do
    Archive.update(:missions, mission.id, &Map.put(&1, :input_return_phase, phase))

    reason =
      "#{phase} asked the operator #{length(held)} " <>
        "#{if length(held) == 1, do: "question", else: "questions"}"

    Missions.transition_phase(mission.id, @gate_phase, reason)

    GiTF.Telemetry.emit([:gitf, :mission, :input_requested], %{count: length(held)}, %{
      mission_id: mission.id,
      phase: phase
    })

    Logger.info("Quest #{mission.id}: holding at #{@gate_phase} — #{reason}")

    {:held, phase}
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  # -- The held mission --------------------------------------------------------

  @doc """
  Drives a mission that is sitting at `awaiting_input`.

  While anything is open: escalate whatever has gone stale and keep
  holding. Nothing here answers, expires or fails the mission — see
  `GiTF.Inquiry`'s moduledoc for why auto-answering is refused where
  auto-approving is permitted.

  Once every question is answered: transition back to the asking phase
  and re-dispatch it, so the phase runs again with the answer in its
  prompt. Mirrors `GiTF.Approval.handle_result/1`'s shape and is called
  from the same place in the advance loop.
  """
  @spec handle_result(map()) :: {:ok, String.t()} | {:error, term()}
  def handle_result(mission) do
    if Inquiry.open?(mission.id) do
      Inquiry.escalate_stale(mission.id)
      {:ok, @gate_phase}
    else
      resume_asking_phase(mission)
    end
  end

  @doc """
  Returns the mission to the phase that asked, and re-dispatches it.

  The return phase is read from `input_return_phase`, written when the
  mission was held. A record that somehow lacks it falls back to the
  last non-gate phase in the transition log rather than guessing at a
  position in the ladder — a mission is never routed to a phase it has
  no evidence of having been in.
  """
  @spec resume_asking_phase(map()) :: {:ok, String.t()} | {:error, term()}
  def resume_asking_phase(mission) do
    case return_phase(mission) do
      nil ->
        Logger.error(
          "Quest #{mission.id} is at #{@gate_phase} with every question answered but no " <>
            "recorded return phase — holding rather than guessing where it belongs"
        )

        Observability.Alerts.dispatch_webhook(
          :input_return_unknown,
          "Quest #{mission.id}: answered but the phase to return to was never recorded — " <>
            "it needs a human to route it",
          dedup_key: "input_return_unknown:#{mission.id}"
        )

        {:ok, @gate_phase}

      phase ->
        answers = Inquiry.answered_register(mission.id)

        Logger.info(
          "Quest #{mission.id}: all #{length(answers)} questions answered — returning to #{phase}"
        )

        Missions.transition_phase(
          mission.id,
          phase,
          "operator answered; re-running #{phase} with the decision"
        )

        GiTF.Telemetry.emit([:gitf, :mission, :input_answered], %{count: length(answers)}, %{
          mission_id: mission.id,
          phase: phase
        })

        {:ok, mission} = Missions.get(mission.id)
        redispatch(mission, phase)
    end
  end

  # The transition is committed BEFORE the dispatch, and the dispatch is
  # wrapped, on purpose. A phase starter that raises must not take the
  # advance loop down with it, and it must not leave the mission parked on
  # a gate whose questions are all answered — the phase is the recoverable
  # place to be stuck, because the Janitor's stuck-phase sweep can re-spawn
  # from there. (`WorkflowBridge` makes the same call about a handler that
  # raises.)
  defp redispatch(mission, phase) do
    GiTF.Major.Orchestrator.dispatch_phase(phase, mission)
  rescue
    e ->
      Logger.error(
        "Quest #{mission.id}: re-dispatching #{phase} after an answer raised " <>
          "(#{Exception.message(e)}) — the mission is at #{phase} with the answer recorded"
      )

      {:ok, phase}
  end

  @doc """
  Workflow-path entry for `awaiting_input`.

  Refuses to hold a mission that has nothing open. The gate exists to
  represent a question that was actually asked; parking a mission here
  without one is how a mission waits forever on nobody.
  """
  @spec start(map()) :: {:ok, String.t()} | {:error, term()}
  def start(mission) do
    if Inquiry.open?(mission.id) do
      Missions.transition_phase(mission.id, @gate_phase, "holding for an operator answer")
      {:ok, @gate_phase}
    else
      {:error, :no_open_inquiry}
    end
  end

  defp return_phase(mission) do
    case Map.get(mission, :input_return_phase) do
      phase when is_binary(phase) and phase != "" -> phase
      _ -> last_non_gate_phase(mission)
    end
  end

  defp last_non_gate_phase(mission) do
    mission.id
    |> Missions.get_phase_transitions()
    |> Enum.reverse()
    |> Enum.find_value(fn transition ->
      from = transition[:from_phase]
      if is_binary(from) and holdable_phase?(from), do: from
    end)
  rescue
    _ -> nil
  end
end
