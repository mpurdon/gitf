defmodule GiTF.Inquiry do
  @moduledoc """
  THE INPUT GATE — a phase asking the operator a question it cannot
  honestly answer itself, and the mission holding until it is answered.

  Before this existed the factory could stop for a human in exactly one
  place: `awaiting_approval`. That gate is binary (ship / don't), it
  fires at the very END after everything is already built, and it can
  only ask the one question it was born asking. So any piece of work
  containing genuine taste — *which of these three approaches?*, *what
  should this be called?*, *is this the look you wanted?* — had two
  outcomes and no third. Either the factory guessed and the operator
  found out ninety minutes later at the approval gate, or the work never
  went through the factory at all. Both are the factory failing at its
  job.

  An inquiry is the third outcome. Any phase may raise one; the mission
  holds at `awaiting_input`; the operator answers over the MCP or the
  Catwalk; the asking phase re-runs with the answer in its prompt.

  ## What an inquiry is NOT

  It is not a chat channel. A factory that asks six questions per
  mission has converted an autonomous system into a chat interface with
  a ninety-second turn latency, and that is *worse* than one that never
  asks. Two guardrails hold the line and both are hard refusals, not
  warnings:

    * **A budget per mission** — `[:inquiries, :max_per_mission]`,
      default 3. Past it `ask/2` returns `{:error, {:budget_exhausted,
      n}}` and the phase proceeds on its own judgement. Losing one
      question is cheaper than losing the autonomy.
    * **A question must be answerable on its own terms.** `validate/1`
      refuses a blank prompt, a `:choice` with fewer than two options, an
      option with no label, and a missing `key`. A malformed question is
      rejected loudly at the seam rather than parking a mission on a
      prompt no human can act on — a mission held forever on an
      unanswerable question is the worst outcome this module can produce.

  ## Timeout policy — deliberately unlike approval

  `GiTF.Approval` auto-approves on timeout, and that is defensible: the
  work already passed validation, the timeout re-validates before it
  fires, and the fail direction (merge reviewed-by-machine work) is
  recoverable by revert.

  An inquiry has no such fail-safe direction. Auto-answering means
  **picking a design because the operator was asleep** — silently
  substituting the factory's taste for the human's on precisely the
  decision that was escalated *because* the factory's taste was not
  trusted. The result then travels forward through planning,
  implementation and validation, and nothing downstream can tell an
  operator's choice from a timeout's. There is no revert for that.

  So this gate does not auto-answer, ever. It alerts once per inquiry
  after `[:inquiries, :alert_hours]` (default 1) of AWAKE time and then
  keeps holding. A held mission is visible in three places (the
  Questions panel, the mission detail page, `list_questions`); waiting
  is the correct behaviour and the operator is told it is waiting.

  ## Durability across a resume

  An answer is a decision the operator already made, and a resumed run
  that re-asks it has spent the operator's attention twice on one
  question. Answered inquiries therefore cross the resume boundary the
  way `contested_requirements` does — `Missions.create_resumed_record/3`
  seeds the child's `answered_inquiries` register from the lineage, and
  `ask/2` consults it *before* creating anything. The register is keyed
  on `{phase, key}`, never on prompt text: a ghost rewording its own
  question between runs must not read as a new one.
  """

  require Logger

  alias GiTF.{Archive, Observability}
  alias GiTF.Config.Provider, as: ConfigProvider

  # The one phase whose meaning is "the factory has stopped and a human
  # owes it an answer". Sibling of GiTF.Approval's @gate_phase.
  @gate_phase "awaiting_input"

  @kinds [:choice, :text, :confirm]

  # The gate itself, the terminal phases, and the phases with no ghost to
  # ask with. `sync`, `publish` and `scoring` write artifacts too, but a
  # `questions` key on one of them is a bug in something else rather than a
  # question — and by then the decision has been built either way.
  @non_asking_phases ~w(
    pending awaiting_input awaiting_approval sync publish scoring
    completed failed closed killed
  )

  @doc "The phase id a mission holds at while an inquiry is open."
  @spec gate_phase() :: String.t()
  def gate_phase, do: @gate_phase

  @doc "The question kinds an inquiry may take."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  Whether a phase is one that may raise a question at all.

  Shared by the interception in `GiTF.Inquiry.Gate` and the invitation in
  the prompt, so a phase cannot be invited to ask something the gate
  would then ignore.
  """
  @spec askable_phase?(term()) :: boolean()
  def askable_phase?(phase) when is_binary(phase), do: phase not in @non_asking_phases
  def askable_phase?(_), do: false

  # -- Asking ------------------------------------------------------------------

  @doc """
  Raise a question against `mission_id`, or hand back the answer it
  already has.

  `attrs` must carry a `:key` (stable, caller-supplied), a `:phase`, a
  `:kind` and a `:prompt`; `:choice` additionally needs `:options`. See
  `validate/1` for the full contract.

  Four outcomes, all of them `{:ok, _, tag}` or a loud error:

    * `{:ok, inquiry, :asked}` — a new open question. The caller should
      hold the mission.
    * `{:ok, inquiry, :open}` — this exact question is already open.
      Idempotent: re-asking on a later advance sweep creates nothing.
    * `{:ok, inquiry, :already_answered}` — answered, here or by an
      ancestor run. The caller must NOT hold; read `inquiry.answer`.
      This is the loop breaker: a re-dispatched phase that asks its
      question again gets the answer instead of a second hold.
    * `{:error, {:invalid, reason}}` / `{:error, {:budget_exhausted, n}}`
      — the question was refused. Nothing was recorded and the mission
      was not held.
  """
  @spec ask(String.t(), map()) ::
          {:ok, map(), :asked | :open | :already_answered} | {:error, term()}
  def ask(mission_id, attrs) when is_binary(mission_id) and is_map(attrs) do
    with {:ok, question} <- validate(attrs) do
      case existing(mission_id, question.phase, question.key) do
        %{status: "answered"} = answered ->
          {:ok, answered, :already_answered}

        %{status: "open"} = open ->
          {:ok, open, :open}

        nil ->
          ask_fresh(mission_id, question)
      end
    end
  end

  # An answer inherited from the lineage is materialized as a real
  # record on the child rather than being read out of the register in
  # place. Every surface (the panel, list_questions, the mission page)
  # then reads one shape, and the child's own history says plainly that
  # the question was asked and answered — stamped `inherited_from`, the
  # same honesty `Missions.inherit_artifacts/3` applies to artifacts.
  defp ask_fresh(mission_id, question) do
    case inherited_answer(mission_id, question.phase, question.key) do
      %{} = prior ->
        {:ok, record} = insert_inherited(mission_id, question, prior)
        {:ok, record, :already_answered}

      nil ->
        budget = max_per_mission()
        asked = count_asked_here(mission_id)

        if asked >= budget do
          Logger.warning(
            "Quest #{mission_id}: inquiry budget exhausted (#{asked}/#{budget}) — refusing " <>
              "#{question.phase}/#{question.key}. The phase proceeds on its own judgement."
          )

          {:error, {:budget_exhausted, budget}}
        else
          insert_open(mission_id, question)
        end
    end
  end

  defp insert_open(mission_id, question) do
    {:ok, record} =
      Archive.insert(:inquiries, %{
        mission_id: mission_id,
        key: question.key,
        phase: question.phase,
        kind: question.kind,
        prompt: question.prompt,
        options: question.options,
        default: question.default,
        asked_by: question.asked_by,
        asked_at: DateTime.utc_now(),
        status: "open"
      })

    Logger.info(
      "Quest #{mission_id}: #{question.phase} asked the operator #{question.kind} " <>
        "#{question.key} (#{record.id})"
    )

    announce(record)
    {:ok, record, :asked}
  end

  defp insert_inherited(mission_id, question, prior) do
    Logger.info(
      "Quest #{mission_id}: #{question.phase}/#{question.key} was already answered by " <>
        "#{prior["mission_id"] || "an ancestor run"} — inheriting the answer, not re-asking"
    )

    Archive.insert(:inquiries, %{
      mission_id: mission_id,
      key: question.key,
      phase: question.phase,
      kind: question.kind,
      prompt: question.prompt,
      options: question.options,
      default: question.default,
      asked_by: question.asked_by,
      asked_at: DateTime.utc_now(),
      status: "answered",
      answer: prior["answer"],
      answer_label: prior["answer_label"],
      answered_by: prior["answered_by"],
      answered_at: prior["answered_at"],
      inherited_from: prior["mission_id"]
    })
  end

  # Best-effort, both of them: a mission must not fail to hold because a
  # notification channel was down.
  defp announce(record) do
    Observability.Alerts.dispatch_webhook(
      :input_requested,
      "Quest #{record.mission_id} is holding for an answer (#{record.phase}): " <>
        String.slice(record.prompt, 0, 120) <> questions_link(),
      dedup_key: "input_requested:#{record.id}"
    )

    Phoenix.PubSub.broadcast(
      GiTF.PubSub,
      "section:alerts",
      {:input_requested, record.mission_id, record.id}
    )
  rescue
    _ -> :ok
  end

  # -- Validation --------------------------------------------------------------

  @doc """
  Normalizes and checks a question, or says exactly what is wrong with
  it.

  The contract, all of it enforced:

    * `key` — non-empty string. The stable identity of the question
      across re-asks and across a resume. Prompt text is NOT an
      acceptable identity; a ghost rewording itself would then re-ask.
    * `phase` — non-empty string, the phase to return to.
    * `kind` — one of `#{inspect(@kinds)}`.
    * `prompt` — non-empty after trimming. A blank prompt is a mission
      held on nothing.
    * `options` — `:choice` only, at least two, each with a non-empty
      `label`. An `id` is derived from the label when absent and must be
      unique. `rationale` is optional but is the whole point of the
      shape: the operator has to be able to judge between the options
      without reading the code.

  Returns `{:ok, normalized}` or `{:error, {:invalid, reason}}`.
  """
  @spec validate(map()) :: {:ok, map()} | {:error, {:invalid, String.t()}}
  def validate(attrs) when is_map(attrs) do
    with {:ok, key} <- require_text(attrs, [:key, "key"], "key"),
         {:ok, phase} <- require_text(attrs, [:phase, "phase"], "phase"),
         {:ok, kind} <- require_kind(attrs),
         {:ok, prompt} <- require_text(attrs, [:prompt, "prompt"], "prompt"),
         {:ok, options} <- require_options(kind, attrs) do
      {:ok,
       %{
         key: key,
         phase: phase,
         kind: kind,
         prompt: prompt,
         options: options,
         default: fetch(attrs, [:default, "default"]),
         asked_by: fetch(attrs, [:asked_by, "asked_by"]) || "phase:#{phase}"
       }}
    end
  end

  def validate(_), do: {:error, {:invalid, "a question must be a map"}}

  defp require_text(attrs, keys, name) do
    case fetch(attrs, keys) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:invalid, "#{name} cannot be blank"}}
          trimmed -> {:ok, trimmed}
        end

      nil ->
        {:error, {:invalid, "#{name} is required"}}

      other ->
        {:error, {:invalid, "#{name} must be a string, got #{inspect(other, limit: 5)}"}}
    end
  end

  defp require_kind(attrs) do
    case fetch(attrs, [:kind, "kind"]) do
      kind when kind in @kinds ->
        {:ok, kind}

      kind when is_binary(kind) ->
        case Enum.find(@kinds, &(to_string(&1) == kind)) do
          nil -> {:error, {:invalid, "kind must be one of #{kind_list()}, got #{inspect(kind)}"}}
          found -> {:ok, found}
        end

      other ->
        {:error,
         {:invalid, "kind must be one of #{kind_list()}, got #{inspect(other, limit: 5)}"}}
    end
  end

  defp kind_list, do: Enum.map_join(@kinds, ", ", &inspect/1)

  # Two is the floor, not a style preference: a "choice" with one option
  # is not a question, it is a phase asking the operator to rubber-stamp
  # a decision it already made, at the cost of however long they were
  # asleep.
  defp require_options(:choice, attrs) do
    case fetch(attrs, [:options, "options"]) do
      options when is_list(options) and length(options) >= 2 ->
        normalize_options(options)

      options when is_list(options) ->
        {:error,
         {:invalid,
          "a :choice needs at least 2 options, got #{length(options)} — " <>
            "a one-option choice is not a question"}}

      _ ->
        {:error, {:invalid, "a :choice needs an options list"}}
    end
  end

  defp require_options(_kind, _attrs), do: {:ok, []}

  defp normalize_options(options) do
    normalized = Enum.map(options, &normalize_option/1)

    case Enum.find(normalized, &match?({:error, _}, &1)) do
      {:error, _} = bad ->
        bad

      nil ->
        ids = Enum.map(normalized, & &1.id)

        if length(Enum.uniq(ids)) == length(ids) do
          {:ok, normalized}
        else
          {:error, {:invalid, "option ids must be unique, got #{inspect(ids)}"}}
        end
    end
  end

  defp normalize_option(option) when is_map(option) do
    label = fetch(option, [:label, "label"])

    case is_binary(label) && String.trim(label) do
      trimmed when is_binary(trimmed) and trimmed != "" ->
        %{
          id: option_id(option, trimmed),
          label: trimmed,
          rationale: trim_or_nil(fetch(option, [:rationale, "rationale"]))
        }

      _ ->
        {:error, {:invalid, "every option needs a non-empty label"}}
    end
  end

  defp normalize_option(other),
    do: {:error, {:invalid, "every option must be a map, got #{inspect(other, limit: 5)}"}}

  defp option_id(option, label) do
    case fetch(option, [:id, "id"]) do
      id when is_binary(id) ->
        case String.trim(id) do
          "" -> slug(label)
          trimmed -> trimmed
        end

      _ ->
        slug(label)
    end
  end

  defp slug(label) do
    label
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
    |> case do
      "" -> "option"
      s -> s
    end
  end

  defp trim_or_nil(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_or_nil(_), do: nil

  defp fetch(map, keys), do: Enum.find_value(keys, fn key -> Map.get(map, key) end)

  # -- Answering ---------------------------------------------------------------

  @doc """
  Records `answer` against inquiry `id`.

  Idempotent by construction, and deliberately so in BOTH directions: an
  already-answered inquiry returns its EXISTING answer with the
  `:already_answered` tag whether the second answer agrees with the first
  or contradicts it. A conflicting second answer is not an error — it is
  a caller who did not know the question had already been decided, and
  handing them the standing decision tells them that, where an opaque
  `{:error, :invalid_transition}` would not. (`Missions.resume_with_status/3`
  settled this shape for the same reason: `:already_resumed` beat an error.)

  The first answer wins because work has already been re-dispatched
  against it. Changing an answer is a new question, not an edit.

  `opts`:
    * `:answered_by` — who decided. Recorded verbatim; the surfaces name
      themselves (`"mcp_operator"`, a tailnet login) rather than
      inventing a human.

  Returns `{:ok, inquiry, :answered | :already_answered}` or
  `{:error, :not_found}` / `{:error, {:invalid, reason}}`.
  """
  @spec answer(String.t(), term(), keyword()) ::
          {:ok, map(), :answered | :already_answered} | {:error, term()}
  def answer(id, answer, opts \\ []) when is_binary(id) do
    case Archive.get(:inquiries, id) do
      nil ->
        {:error, :not_found}

      %{status: "answered"} = decided ->
        {:ok, decided, :already_answered}

      inquiry ->
        with {:ok, value, label} <- validate_answer(inquiry, answer) do
          answered_by = Keyword.get(opts, :answered_by, "human")
          now = DateTime.utc_now()

          {:ok, updated} =
            Archive.update(:inquiries, id, fn record ->
              # Re-checked INSIDE the update: two operators answering the
              # same question in the same second must not both win, and
              # the read above is not a lock.
              case record[:status] do
                "answered" ->
                  record

                _ ->
                  record
                  |> Map.put(:status, "answered")
                  |> Map.put(:answer, value)
                  |> Map.put(:answer_label, label)
                  |> Map.put(:answered_by, answered_by)
                  |> Map.put(:answered_at, now)
              end
            end)

          Logger.info(
            "Quest #{updated.mission_id}: inquiry #{id} (#{updated.phase}/#{updated.key}) " <>
              "answered by #{updated[:answered_by]}"
          )

          {:ok, updated, if(updated[:answered_at] == now, do: :answered, else: :already_answered)}
        end
    end
  end

  @doc """
  Checks a proposed answer against the question's kind, returning the
  stored value and the label to show for it.

  A `:choice` answer must name an option that exists — accepting an
  unknown id would record a decision nothing downstream can act on.
  """
  @spec validate_answer(map(), term()) :: {:ok, term(), String.t()} | {:error, {:invalid, term()}}
  def validate_answer(%{kind: :choice} = inquiry, answer) do
    options = inquiry[:options] || []

    case Enum.find(options, &(&1.id == answer or &1.label == answer)) do
      nil ->
        {:error,
         {:invalid,
          "no option #{inspect(answer)} on this question — valid ids: " <>
            Enum.map_join(options, ", ", & &1.id)}}

      option ->
        {:ok, option.id, option.label}
    end
  end

  def validate_answer(%{kind: :confirm}, answer) do
    case normalize_confirm(answer) do
      nil -> {:error, {:invalid, "a :confirm answer must be true or false"}}
      bool -> {:ok, bool, if(bool, do: "yes", else: "no")}
    end
  end

  def validate_answer(%{kind: :text}, answer) when is_binary(answer) do
    case String.trim(answer) do
      "" -> {:error, {:invalid, "a :text answer cannot be blank"}}
      trimmed -> {:ok, trimmed, String.slice(trimmed, 0, 60)}
    end
  end

  def validate_answer(%{kind: :text}, _),
    do: {:error, {:invalid, "a :text answer must be a string"}}

  def validate_answer(_inquiry, _answer), do: {:error, {:invalid, "unknown question kind"}}

  defp normalize_confirm(true), do: true
  defp normalize_confirm(false), do: false
  defp normalize_confirm(value) when value in ["true", "yes", "y"], do: true
  defp normalize_confirm(value) when value in ["false", "no", "n"], do: false
  defp normalize_confirm(_), do: nil

  # -- Reading -----------------------------------------------------------------

  @doc "One inquiry by id, or nil."
  @spec get(String.t()) :: map() | nil
  def get(id) when is_binary(id), do: Archive.get(:inquiries, id)
  def get(_), do: nil

  @doc """
  `:open`, `:answered`, or `:unknown` for an id that names nothing.
  """
  @spec status(String.t()) :: :open | :answered | :unknown
  def status(id) do
    case get(id) do
      %{status: "open"} -> :open
      %{status: "answered"} -> :answered
      _ -> :unknown
    end
  end

  @doc """
  Open inquiries, oldest first — for one mission, or every mission when
  called with no argument. Oldest first because the operator should
  answer the question that has been holding a mission longest.
  """
  @spec list_open(String.t() | nil) :: [map()]
  def list_open(mission_id \\ nil)

  def list_open(nil) do
    Archive.filter(:inquiries, &(&1[:status] == "open")) |> oldest_first()
  end

  def list_open(mission_id) when is_binary(mission_id) do
    mission_id |> for_mission() |> Enum.filter(&(&1[:status] == "open")) |> oldest_first()
  end

  @doc "Every inquiry raised against a mission, oldest first."
  @spec list(String.t()) :: [map()]
  def list(mission_id) when is_binary(mission_id),
    do: mission_id |> for_mission() |> oldest_first()

  @doc "True when the mission has at least one unanswered question."
  @spec open?(String.t()) :: boolean()
  def open?(mission_id) when is_binary(mission_id), do: list_open(mission_id) != []
  def open?(_), do: false

  defp for_mission(mission_id) do
    Archive.by_index(:inquiries, :mission_id, mission_id)
  rescue
    _ -> Archive.filter(:inquiries, &(&1[:mission_id] == mission_id))
  end

  defp oldest_first(records) do
    Enum.sort_by(records, &(&1[:asked_at] || &1[:inserted_at]), {:asc, DateTime})
  end

  defp existing(mission_id, phase, key) do
    mission_id
    |> for_mission()
    |> Enum.find(&(&1[:phase] == phase and &1[:key] == key))
  end

  # Only questions this run actually put to a human count against the
  # budget. An inherited answer cost the operator nothing.
  defp count_asked_here(mission_id) do
    mission_id |> for_mission() |> Enum.count(&is_nil(&1[:inherited_from]))
  end

  # -- The answered register (crosses a resume) --------------------------------

  @doc """
  Every answered inquiry for `mission_id`, in the register shape that
  survives a resume: string-keyed maps, safe to store on a mission
  record and read back by an unrelated run.
  """
  @spec answered_register(String.t()) :: [map()]
  def answered_register(mission_id) when is_binary(mission_id) do
    mission_id
    |> for_mission()
    |> Enum.filter(&(&1[:status] == "answered"))
    |> oldest_first()
    |> Enum.map(&to_register_entry/1)
  end

  def answered_register(_), do: []

  @doc false
  def to_register_entry(inquiry) do
    %{
      "mission_id" => inquiry[:inherited_from] || inquiry[:mission_id],
      "phase" => inquiry[:phase],
      "key" => inquiry[:key],
      "kind" => to_string(inquiry[:kind]),
      "prompt" => inquiry[:prompt],
      "answer" => inquiry[:answer],
      "answer_label" => inquiry[:answer_label],
      "answered_by" => inquiry[:answered_by],
      "answered_at" => inquiry[:answered_at] && to_string(inquiry[:answered_at])
    }
  end

  # The child's own records first, then the register it inherited — a
  # decision made in THIS run outranks the one it was seeded with.
  defp inherited_answer(mission_id, phase, key) do
    case Archive.get(:missions, mission_id) do
      %{} = mission ->
        Enum.find(mission[:answered_inquiries] || [], fn entry ->
          is_map(entry) and entry["phase"] == phase and entry["key"] == key
        end)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc """
  The answers a phase ghost must be told about, rendered for a prompt.

  Injected once, into `GiTF.Intel.get_prompt_context/3`, so EVERY phase
  prompt carries it rather than each builder having to remember. A
  re-dispatched phase that cannot see the answer it asked for would ask
  again, and the only thing standing between that and an infinite hold
  would be the budget.

  Returns `""` when the mission has no answered inquiries, so it costs
  nothing on the overwhelming majority of runs.
  """
  @spec prompt_block(String.t()) :: String.t()
  def prompt_block(mission_id) when is_binary(mission_id) do
    case answered_register(mission_id) do
      [] ->
        ""

      entries ->
        lines =
          Enum.map_join(entries, "\n", fn entry ->
            "- (#{entry["phase"]}/#{entry["key"]}) #{entry["prompt"]}\n" <>
              "  ANSWER: #{entry["answer_label"] || entry["answer"]}"
          end)

        """
        ## OPERATOR DECISIONS

        The operator was asked these questions and answered them. These are
        DECISIONS, not suggestions — build to them, do not re-litigate them,
        and do not ask them again.

        #{lines}
        """
    end
  end

  def prompt_block(_), do: ""

  @doc """
  Whether phase ghosts are INVITED to ask questions
  (`[:inquiries, :enabled]`, default `false`).

  The gate itself is always live: a phase that emits `questions` is
  always honoured, so a workflow, an agent profile or a hand-written
  prompt can opt in without touching config. This flag governs only
  whether every phase prompt carries the invitation.

  It ships off, and the reason is money rather than caution. A held
  mission is non-terminal, non-terminal missions keep the box from
  idle-stopping, and the box costs real EC2 hours while it waits. Turning
  the invitation on factory-wide is therefore a decision that can raise a
  bill — one design ghost that decides "which approach?" is always worth
  asking would hold every mission it touches until someone woke up. That
  is the operator's call to make deliberately, not a default they
  discover on an invoice.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: ConfigProvider.get([:inquiries, :enabled], false) == true

  @doc """
  The invitation, rendered for a phase prompt: what a question is for,
  the exact JSON shape, and — at length — when NOT to ask.

  Returns `""` when the invitation is off or the mission's budget is
  spent. A ghost told it may ask three questions when it may ask none
  would spend its output on one and get refused at the seam.
  """
  @spec invitation_block(String.t(), String.t()) :: String.t()
  def invitation_block(mission_id, phase) when is_binary(mission_id) and is_binary(phase) do
    remaining = enabled?() && askable_phase?(phase) && budget_remaining(mission_id)

    if remaining in [false, 0] do
      ""
    else
      """
      ## ASKING THE OPERATOR

      If this phase turns on a decision that is genuinely the operator's —
      a matter of taste, product direction, or naming, where two answers
      are both defensible and the code cannot tell you which is wanted —
      you may add a `questions` array to your JSON artifact. The mission
      will HOLD until a human answers, and this phase will then run again
      with their answer.

      Ask only when ALL of these are true:

      - The answer is not discoverable. If reading the repo, the goal, or
        the earlier artifacts would settle it, read them instead.
      - Getting it wrong is expensive to undo — it shapes what gets built,
        not just how a line is written.
      - The operator can answer it in ten seconds, from your options
        alone, without opening the code.

      Do NOT ask to confirm a decision you have already made, to hedge, to
      check your work, or because a requirement is ambiguous in a way you
      could resolve by picking the conservative reading and saying so.
      Holding a mission costs the operator's attention and the factory's
      wall clock; a question that did not need asking is worse than a
      decision made and explained. You may ask at most #{remaining} more on
      this mission; most missions should ask none.

      Shape (omit the key entirely if you have nothing to ask):

      ```json
      "questions": [
        {
          "key": "stable-slug-for-this-question",
          "kind": "choice",
          "prompt": "One sentence. What is being decided and why it is theirs.",
          "options": [
            {"id": "a", "label": "Short name", "rationale": "What this buys and what it costs."},
            {"id": "b", "label": "Short name", "rationale": "What this buys and what it costs."}
          ]
        }
      ]
      ```

      `kind` is `"choice"` (needs 2+ options), `"text"` (free-form answer),
      or `"confirm"` (yes/no). `key` must be stable: if you ask the same
      question again after being answered, the same `key` returns the
      standing answer instead of asking the operator twice.
      """
    end
  end

  def invitation_block(_, _), do: ""

  # -- The gate ----------------------------------------------------------------

  @doc """
  Where a mission stands relative to the input gate, for the pipeline
  widgets:

    * `:held` — sitting on the gate right now. A human owes it an answer.
    * `:answered` — questions were asked and every one of them was
      answered. The mission moved on.
    * `:skipped` — nothing was ever asked. Most missions, most of the
      time.
    * `:future` — the mission is still running and may yet ask.

  Same contract and same conservatism as `GiTF.Approval.gate_state/1`,
  and for the same reason: msn-ac0539 sat blocked on a human for twelve
  hours while both widgets rendered it as the factory merging. A gate
  that has not fired renders `:future` on a live mission and `:skipped`
  on a finished one — a dead mission is not waiting for anything, and a
  pending-looking step on a dead mission is the same lie in a different
  colour.

  Unlike the approval gate this one has NO position in the pipeline, so
  there is no "past the gate point" to test: any phase can raise it. The
  question is only ever "did this mission ask, and has it been answered".
  """
  @spec gate_state(map()) :: :future | :held | :answered | :skipped
  def gate_state(mission) when is_map(mission) do
    cond do
      Map.get(mission, :current_phase) == @gate_phase -> :held
      not is_binary(Map.get(mission, :id)) -> :future
      true -> from_records(mission)
    end
  rescue
    # A widget must not take the page down because the store hiccuped.
    # `:future` claims nothing about what a human did.
    _ -> :future
  end

  def gate_state(_), do: :future

  defp from_records(mission) do
    case list(mission.id) do
      [] -> if terminal?(mission), do: :skipped, else: :future
      records -> if Enum.any?(records, &(&1[:status] == "open")), do: :held, else: :answered
    end
  end

  @terminal_statuses ~w(completed closed killed failed)

  defp terminal?(mission), do: Map.get(mission, :status) in @terminal_statuses

  # -- Waiting -----------------------------------------------------------------

  @doc """
  Alerts the operator once per inquiry that has been open longer than
  `alert_hours`, and returns how many it alerted about.

  This is the whole timeout policy. Nothing here answers, expires or
  fails anything — see the moduledoc for why auto-answering is refused
  where auto-approving is permitted. The alert is the escalation and the
  hold is the outcome.

  Elapsed is AWAKE time (`GiTF.Clock.awake_elapsed/1`) with the boot
  grace respected, so an idle-stopped box does not burn the window and a
  wake does not immediately page about everything at once.
  """
  @spec escalate_stale(String.t()) :: non_neg_integer()
  def escalate_stale(mission_id) when is_binary(mission_id) do
    if GiTF.Clock.in_boot_grace?() do
      0
    else
      mission_id |> list_open() |> Enum.count(&maybe_alert/1)
    end
  rescue
    e ->
      Logger.warning("Inquiry escalation failed for #{mission_id}: #{Exception.message(e)}")
      0
  end

  defp maybe_alert(inquiry) do
    cond do
      inquiry[:alerted_at] != nil ->
        false

      awake_hours(inquiry[:asked_at]) <= alert_hours() ->
        false

      true ->
        Archive.update(:inquiries, inquiry.id, &Map.put(&1, :alerted_at, DateTime.utc_now()))

        Observability.Alerts.dispatch_webhook(
          :input_stalled,
          "Quest #{inquiry.mission_id} has been holding #{round(awake_hours(inquiry[:asked_at]))}h " <>
            "for an answer (#{inquiry.phase}): #{String.slice(inquiry.prompt, 0, 120)}\n" <>
            "It will keep holding — this gate never auto-answers." <> questions_link(),
          dedup_key: "input_stalled:#{inquiry.id}"
        )

        true
    end
  end

  defp awake_hours(nil), do: 0.0
  defp awake_hours(at), do: GiTF.Clock.awake_elapsed(at) / 3600

  @doc "How long an inquiry may sit before the operator is paged, in awake hours."
  @spec alert_hours() :: number()
  def alert_hours, do: ConfigProvider.get([:inquiries, :alert_hours], 1)

  @doc """
  How many questions one mission may put to the operator.

  Three, by default. It is a budget on the operator's attention, not on
  the store: the fourth question is refused so the mission stays a
  mission rather than becoming a conversation.
  """
  @spec max_per_mission() :: pos_integer()
  def max_per_mission, do: ConfigProvider.get([:inquiries, :max_per_mission], 3)

  @doc "Questions remaining in this mission's budget."
  @spec budget_remaining(String.t()) :: non_neg_integer()
  def budget_remaining(mission_id) when is_binary(mission_id),
    do: max(max_per_mission() - count_asked_here(mission_id), 0)

  # Deep link into the Catwalk when the operator has configured the
  # server's own URL; alerts stay plain text otherwise.
  defp questions_link do
    case GiTF.Config.server_url() do
      url when is_binary(url) and url != "" ->
        "\n#{String.trim_trailing(url, "/")}/dashboard/questions"

      _ ->
        ""
    end
  end
end
