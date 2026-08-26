defmodule GiTF.Workflow.Phase do
  @moduledoc """
  Typed phase configuration. One element of a `GiTF.Workflow`.

  ## Fields

  | Field              | Type                  | Notes                                                              |
  |--------------------|-----------------------|--------------------------------------------------------------------|
  | `id`               | String.t              | Unique within the workflow. Stable identifier the orchestrator
                                                  references on phase advance. Lowercase, snake_case.                  |
  | `handler`          | module()              | Implements `GiTF.Phase` behaviour. Wraps a `start_<phase>/1` flow. |
  | `next`             | String.t \\| [transition] \\| nil | Where to advance on completion. A plain string is an unconditional target (`"end"` terminates). A list of conditional transitions — `{when_expr, target}` rules plus a final `{:else, target}` — is evaluated top-to-bottom (via `GiTF.Workflow.Expr`) against the just-completed phase's artifact + the mission; first match wins. |
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

  Either `next` (unconditional or conditional) or both `on_pass` and
  `on_fail` (verdict-driven) must be present. Schema validation enforces
  this.
  """

  @type gate :: %{
          required(:when) => String.t(),
          required(:action) => :await_operator
        }

  @typedoc """
  One conditional `next` rule. `{when_source, when_ast, target}`
  advances to `target` when `when_source` (a `GiTF.Workflow.Expr`
  string, pre-compiled to `when_ast` at schema load) is truthy;
  `{:else, target}` is the unconditional fallback and must be the last
  rule.
  """
  @type transition :: {String.t(), Macro.t(), String.t()} | {:else, String.t()}

  @type t :: %__MODULE__{
          id: String.t(),
          handler: module() | nil,
          next: String.t() | [transition()] | nil,
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

  @doc "Whether this phase advances to a single fixed `next` target."
  @spec unconditional?(t()) :: boolean()
  def unconditional?(%__MODULE__{next: next}) when is_binary(next) and next != "", do: true
  def unconditional?(_), do: false

  @doc "Whether this phase advances via a list of conditional `next` rules."
  @spec conditional?(t()) :: boolean()
  def conditional?(%__MODULE__{next: next}) when is_list(next) and next != [], do: true
  def conditional?(_), do: false

  @doc """
  Whether this phase follows `next` on completion (fixed or conditional)
  rather than branching on a `:pass`/`:fail` verdict.
  """
  @spec advance_driven?(t()) :: boolean()
  def advance_driven?(phase), do: unconditional?(phase) or conditional?(phase)

  @doc "Whether this phase branches on verdict."
  @spec verdict_driven?(t()) :: boolean()
  def verdict_driven?(%__MODULE__{on_pass: p, on_fail: f}),
    do: branch_present?(p) and branch_present?(f)

  def verdict_driven?(_), do: false

  @doc """
  Whether a `next:`/`on_pass:`/`on_fail:` branch value is populated —
  either a non-empty string target or a non-empty conditional rule list.
  Shared with `GiTF.Workflow.Schema` so the parser and the struct agree.
  """
  @spec branch_present?(term()) :: boolean()
  def branch_present?(b) when is_binary(b) and b != "", do: true
  def branch_present?(b) when is_list(b) and b != [], do: true
  def branch_present?(_), do: false

  @doc """
  Builds a `{source, ast, target}` transition tuple with the `when:`
  expression compiled. Raises if the expression doesn't parse against
  `GiTF.Workflow.Expr`'s grammar. Useful for tests and operator tooling
  that build `%Phase{}` structs directly rather than going through
  `GiTF.Workflow.Schema.validate/2`.
  """
  @spec transition!(String.t(), String.t()) :: transition()
  def transition!(source, target) when is_binary(source) and is_binary(target) do
    case GiTF.Workflow.Expr.compile(source) do
      {:ok, ast} ->
        {source, ast, target}

      {:error, reason} ->
        raise ArgumentError, "bad when-expr #{inspect(source)}: #{inspect(reason)}"
    end
  end
end
