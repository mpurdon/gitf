defmodule GiTF.Workflow.Phase do
  @moduledoc """
  Typed phase configuration. One element of a `GiTF.Workflow`.

  ## Fields

  | Field              | Type                  | Notes                                                              |
  |--------------------|-----------------------|--------------------------------------------------------------------|
  | `id`               | String.t              | Unique within the workflow. Stable identifier the orchestrator
                                                  references on phase advance. Lowercase, snake_case.                  |
  | `handler`          | module()              | Implements `GiTF.Phase` behaviour. Wraps a `start_<phase>/1` flow. |
  | `next`             | String.t \\| nil      | Unconditional next phase id. `"end"` terminates.                   |
  | `on_pass`          | String.t \\| nil      | Next phase when handler returns `:pass`.                           |
  | `on_fail`          | String.t \\| nil      | Next phase when handler returns `:fail`.                           |
  | `max_retries`      | non_neg_integer       | Bound on `:fail` self-loops or `on_fail` revisits.                 |
  | `model_tier`       | atom \\| nil          | `:flash`, `:general`, `:opus` — overrides the default tier.        |
  | `timeout_minutes`  | pos_integer \\| nil   | Hard cap; orchestrator surfaces as `:timeout` verdict on expiry.   |
  | `inject_knowledge` | boolean               | Whether to prepend the knowledge-engine prompt context.            |
  | `inject_skills`    | boolean               | Whether to install retrieved skills into the worktree.             |
  | `reads`            | [String.t]            | Artifact ids this phase consumes (validated against `produces`).   |
  | `produces`         | String.t \\| nil      | Artifact id this phase emits.                                      |
  | `gate`             | gate() \\| nil        | Operator-approval gate config.                                     |
  | `strategies`       | [String.t]            | Optional parallel strategies (M5).                                 |
  | `on_exhausted`     | atom() \\| String.t   | Policy when on_fail self-loop hits `max_retries`. `:fail` (default) marks the mission failed; `:advance` falls through to `on_pass` (review's "give up but proceed" semantic); a phase id string forces dispatch to that target. |
  | `meta`             | map()                 | Free-form, preserved across YAML round-trips.                      |

  Either `next` (unconditional) or both `on_pass` and `on_fail`
  (verdict-driven) must be present. Schema validation enforces this.
  """

  @type gate :: %{
          required(:when) => String.t(),
          required(:action) => :await_operator
        }

  @type t :: %__MODULE__{
          id: String.t(),
          handler: module() | nil,
          next: String.t() | nil,
          on_pass: String.t() | nil,
          on_fail: String.t() | nil,
          max_retries: non_neg_integer(),
          model_tier: atom() | nil,
          timeout_minutes: pos_integer() | nil,
          inject_knowledge: boolean(),
          inject_skills: boolean(),
          reads: [String.t()],
          produces: String.t() | nil,
          gate: gate() | nil,
          strategies: [String.t()],
          on_exhausted: :fail | :advance | String.t(),
          meta: map()
        }

  defstruct id: nil,
            handler: nil,
            next: nil,
            on_pass: nil,
            on_fail: nil,
            max_retries: 0,
            model_tier: nil,
            timeout_minutes: nil,
            inject_knowledge: false,
            inject_skills: false,
            reads: [],
            produces: nil,
            gate: nil,
            strategies: [],
            on_exhausted: :fail,
            meta: %{}

  @doc "Whether this phase advances unconditionally on completion."
  @spec unconditional?(t()) :: boolean()
  def unconditional?(%__MODULE__{next: next}) when is_binary(next) and next != "", do: true
  def unconditional?(_), do: false

  @doc "Whether this phase branches on verdict."
  @spec verdict_driven?(t()) :: boolean()
  def verdict_driven?(%__MODULE__{on_pass: p, on_fail: f}) when is_binary(p) and is_binary(f),
    do: true

  def verdict_driven?(_), do: false
end
