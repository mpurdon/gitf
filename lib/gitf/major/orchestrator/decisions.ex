defmodule GiTF.Major.Orchestrator.Decisions do
  @moduledoc """
  Pure decision functions extracted from `GiTF.Major.Orchestrator`.

  No side effects, no Archive access. The caller does any artifact reads
  and passes the relevant values in. This separation makes the decision
  logic trivially testable and keeps the Orchestrator module focused on
  orchestration (IO, phase transitions, ghost spawning).

  Migration note: `simplify_skippable?/1` and `majority_failed?/1` were
  previously `@doc false` public functions on the Orchestrator module;
  they now live here with the same semantics.
  """

  alias GiTF.Ops
  alias GiTF.Triage

  @type phase_after_triage ::
          :research | :requirements | :design | :review | :planning | :implementation

  @doc """
  Given the triage artifact's `skip_flags` map, returns the first unskipped
  phase in the canonical pipeline order. If all pipeline phases up through
  planning are skipped, returns `:implementation` (the trivial path).

  Skip keys are strings (`"skip_research"`, `"skip_requirements"`, etc.)
  matching the LLM-emitted JSON. A value of literal `true` skips the phase;
  any other value (false, nil, missing key, non-boolean) is treated as
  not-skipped so ambiguous LLM output falls safely toward the fuller
  pipeline.

  `has_design?` says whether a design artifact already exists. Review reads
  the design and nothing else, so review is only a coherent destination when
  there is a design to read — that is true for a resumed mission whose design
  already landed, and false for a fresh triage that skipped design. Without
  this, `skip_design: true` with `skip_review` unset routes straight to a
  review ghost that judges an empty artifact, rejects it, and bounces to
  design anyway, having spent a thinking-tier call and one of the mission's
  bounded redesign attempts.
  """
  @spec next_phase_after_triage(map(), boolean()) :: phase_after_triage()
  def next_phase_after_triage(skip_flags, has_design? \\ false) when is_map(skip_flags) do
    cond do
      not skipped?(skip_flags, "skip_research") -> :research
      not skipped?(skip_flags, "skip_requirements") -> :requirements
      not skipped?(skip_flags, "skip_design") -> :design
      not skipped?(skip_flags, "skip_review") and has_design? -> :review
      not skipped?(skip_flags, "skip_planning") -> :planning
      true -> :implementation
    end
  end

  defp skipped?(skip_flags, key), do: Map.get(skip_flags, key) == true

  @doc """
  Maps a triage complexity atom to the mission's `pipeline_mode` string.
  Only `:complex` triggers the full pipeline; everything else (trivial,
  simple, moderate, nil, unknown) gets the streamlined fast path. The
  streamlined pipeline still runs validation, so misclassification is
  caught downstream.
  """
  @spec pipeline_mode_for_complexity(Triage.complexity() | any()) :: String.t()
  def pipeline_mode_for_complexity(:complex), do: "full"
  def pipeline_mode_for_complexity(_), do: "fast"

  @doc """
  The `pipeline_mode` an inference step should write for `mission`, or `nil`
  when the operator's explicit choice must stand.

  `start_mission --full` / `--fast` (and the MCP `full` / `fast` arguments)
  stamp `pipeline_mode_forced` on the mission. Triage and research both form
  their own opinion afterwards, and without this an operator asking for the
  full pipeline silently got whatever triage inferred — the option was
  advertised and ignored. Inference still wins whenever the operator did not
  ask for anything, which is the common case.
  """
  @spec pipeline_mode_after_inference(map(), Triage.complexity() | any()) :: String.t() | nil
  def pipeline_mode_after_inference(mission, complexity) do
    if forced_pipeline_mode?(mission) do
      nil
    else
      pipeline_mode_for_complexity(complexity)
    end
  end

  @doc """
  True when the mission's `pipeline_mode` was set by an explicit operator
  choice rather than inferred, and so must not be revised.
  """
  @spec forced_pipeline_mode?(map()) :: boolean()
  def forced_pipeline_mode?(mission), do: Map.get(mission, :pipeline_mode_forced) == true

  @doc """
  True when the simplify phase can be elided for a mission of the given
  triage complexity. Scoring still runs so the learning loop keeps getting
  signal — this only skips the 3 parallel simplify review ghosts.
  """
  @spec simplify_skippable?(Triage.complexity() | nil) :: boolean()
  def simplify_skippable?(complexity), do: complexity in [:trivial, :simple]

  @doc """
  Decides whether a mission's implementation ops represent a majority
  failure condition that should trip the fallback/replan path.

  Ops with a retry in flight (`:retried_as` set), a retry still schedulable
  (`retry_pending?/1`), or a successful retry sibling are NOT permanent —
  excluding them prevents a single failure from flipping 1/1 = 100% before
  the retry can resolve. `killed` is treated alongside `failed`/`rejected`
  to match `GiTF.Ops.resolved?/2`.
  """
  @spec majority_failed?([map()]) :: boolean()
  def majority_failed?(impl_jobs) do
    retried_ok = Ops.retried_ok_set(impl_jobs)

    permanent_terminal =
      Enum.filter(impl_jobs, fn op ->
        case op.status do
          "done" ->
            true

          s when s in ["failed", "rejected", "killed"] ->
            not MapSet.member?(retried_ok, op.id) and
              not Ops.retry_pending?(op) and
              is_nil(Map.get(op, :retried_as))

          _ ->
            false
        end
      end)

    failed = Enum.count(permanent_terminal, &(&1.status in ["failed", "rejected", "killed"]))
    total = length(permanent_terminal)

    total > 0 and failed / total > 0.5
  end
end
