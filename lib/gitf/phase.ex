defmodule GiTF.Phase do
  @moduledoc """
  Behaviour every workflow phase handler implements.

  A phase handler is the bridge between the declarative workflow and
  the orchestrator's actual work — spawning the right ghost, building
  the right prompt, recording the right artifact.

  ## Lifecycle

  When the orchestrator advances a mission to phase `X` whose workflow
  config names `handler: GiTF.Phases.X`, it calls:

      handler.start(mission, phase_config, ctx)

  The handler is responsible for:

    1. Transitioning the mission record's `current_phase` (via
       `GiTF.Missions.transition_phase/3`).
    2. Building the prompt (typically via `PhasePrompts.<id>_prompt/n`).
    3. Spawning the phase ghost (via the orchestrator's helper).
    4. Returning `{:ok, :spawned}` synchronously. The ghost completing
       triggers `verdict/1` later.

  When the phase ghost completes and writes an artifact, the
  orchestrator calls:

      handler.verdict(artifact)

  to determine which branch (`on_pass` / `on_fail` / unconditional
  `next`) to follow.

  ## Default implementation

  `GiTF.Phases.Default` delegates to the orchestrator's existing
  hardcoded `start_<phase>/1` functions, keyed on `phase_config.id`.
  This lets us land the workflow DSL without rewriting 13 phase
  starters at once — the migration is progressive.

  Operator-authored handlers (M4 onwards) implement this behaviour
  directly and can be referenced by name in any workflow YAML.
  """

  @type mission :: map()
  @type phase_config :: GiTF.Workflow.Phase.t()
  @type ctx :: %{
          optional(:sector_id) => String.t() | nil,
          optional(:workflow) => GiTF.Workflow.t(),
          optional(:retry_count) => non_neg_integer(),
          optional(any()) => any()
        }

  @typedoc """
  Verdict atoms.

    * `:pass` / `:fail` — verdict-driven phase succeeded / failed; route
      via `on_pass` / `on_fail`.
    * `:advance` — phase done; route via `next:` (string or conditional).
    * `:wait` — phase still running, no artifact yet.
    * `:inconclusive` — verdict couldn't be computed; treated as `:wait`.
    * `:terminal_complete` — finish the workflow at this phase and treat
      the mission as completed (handler's `terminal/2` decides what
      "completed" means — e.g., `Phases.Scoring` calls
      `mark_post_processing_done/1` instead of `complete_quest/2`).
    * `:terminal_fail` — finish the workflow at this phase and treat the
      mission as failed (handler's `terminal/2` decides what "failed"
      means — e.g., `Phases.Scoring` calls `mark_post_processing_failed/2`
      since the mission is already user-visibly completed).

  `:terminal_*` short-circuit `max_retries`/`on_exhausted`; they're for
  cases like "validation's fix budget is exhausted" or "all design
  strategies failed" where the workflow can't recover by retrying.
  """
  @type verdict ::
          :pass | :fail | :advance | :wait | :inconclusive | :terminal_complete | :terminal_fail

  @doc """
  Starts the phase. Returns `{:ok, :spawned}` when the phase ghost was
  successfully launched, `{:ok, :awaiting_operator}` when the phase
  paused for an operator gate, or `{:error, reason}`.
  """
  @callback start(mission(), phase_config(), ctx()) ::
              {:ok, :spawned | :awaiting_operator | atom()} | {:error, term()}

  @doc """
  Reads a phase's artifact and returns the verdict the orchestrator
  should use to pick the next phase. Defaults to `:advance`.

  Implement this 1-arg form when the verdict can be computed from the
  artifact alone. Implement `verdict/2` instead (or as well) when the
  decision needs the mission record (op history, fix-context, operator
  state, retry-budget heuristics).
  """
  @callback verdict(artifact :: term()) :: verdict()

  @doc """
  Same as `verdict/1` but with the mission record available — for
  handlers that need op history (e.g., `Phases.Design` checking that all
  strategy ops are terminal), operator state (e.g., `Phases.AwaitingApproval`
  reading `GiTF.Override.approval_status/1`), or stale-artifact detection
  (e.g., `Phases.Validation` comparing the validation artifact's age to
  the latest impl op).

  The Advancer prefers `verdict/2` when exported, falls back to `verdict/1`,
  and finally to `GiTF.Workflow.Verdict.compute/2`.
  """
  @callback verdict(mission(), artifact :: term()) :: verdict()

  @doc """
  Called by the orchestrator immediately before it dispatches the next
  phase. The handler can run side effects (e.g., promote a selected
  design variant, increment a retry counter, store metadata) without
  the orchestrator needing to know about them.

  `verdict` is the verdict that drove the advance (`:pass | :fail |
  :advance`); `artifact` is the just-completed phase's artifact (may
  be nil for `:advance` phases that produce no output).

  Default no-op when not implemented.
  """
  @callback before_advance(mission(), verdict(), artifact :: term()) :: :ok

  @doc """
  Called when the workflow terminates at this phase — either because
  `next:` resolved to `:end` (workflow `:complete` decision) or because
  retries exhausted / `:terminal_*` verdict (workflow `:retries_exhausted`).

  `kind` is `:complete` (mission finishes successfully) or
  `:retries_exhausted` (mission finishes in failure). `artifact` is the
  just-completed phase's artifact (may be `nil`) — handlers like
  `Phases.Publish` use it to extract a failure reason for telemetry, and
  `Phases.Triage` to pull `bug_evidence` for the `no_work_needed`
  completion artifact.

  The default behaviour, used when this callback isn't exported, is
  `Missions.complete_quest/2` for `:complete` and `Missions.update(id,
  %{status: "failed"})` for `:retries_exhausted`.
  """
  @callback terminal(mission(), kind :: :complete | :retries_exhausted, artifact :: term()) :: :ok

  @optional_callbacks verdict: 1, verdict: 2, before_advance: 3, terminal: 3
end
