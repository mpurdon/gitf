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

  @type verdict :: :pass | :fail | :advance | :inconclusive

  @doc """
  Starts the phase. Returns `{:ok, :spawned}` when the phase ghost was
  successfully launched, `{:ok, :awaiting_operator}` when the phase
  paused for an operator gate, or `{:error, reason}`.
  """
  @callback start(mission(), phase_config(), ctx()) ::
              {:ok, :spawned | :awaiting_operator | atom()} | {:error, term()}

  @doc """
  Reads a phase's artifact and returns the verdict the orchestrator
  should use to pick the next phase.

  Defaults to `:advance` for phases that don't branch on outcome.
  """
  @callback verdict(artifact :: term()) :: verdict()

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

  @optional_callbacks verdict: 1, before_advance: 3
end
