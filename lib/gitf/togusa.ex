defmodule GiTF.Togusa do
  @moduledoc """
  Togusa — goal fulfillment verification and fix coordination.

  Named after the detective of Section 9, Togusa investigates whether
  ghost workers actually achieved their mission objectives. Works in
  tandem with Tachikoma (automated quality gate):

  1. **Tachikoma** runs the quality gate (static analysis, security, tests) — once, no retries
  2. **Togusa** verifies goal fulfillment (LLM-based review against requirements)

  When either check fails, Togusa coordinates the fix loop: spawning a
  fix ghost in the same worktree with accumulated context from all prior
  attempts, and triggering agent profile learning.
  """

  require Logger

  alias GiTF.Togusa.FixContext

  # -- Quality Gate (delegates to Audit, run once) ---------------------------

  @doc """
  Runs the quality gate on a completed op. Calls `Audit.verify_job/1`
  exactly once — no retries against unchanged code.

  Returns `{:ok, :pass | :fail, result}`.
  """
  @spec run_quality_gate(String.t()) :: {:ok, :pass | :fail | :infra, map()} | {:error, term()}
  def run_quality_gate(op_id) do
    GiTF.Audit.verify_job(op_id)
  end

  # -- Fix Request -----------------------------------------------------------

  # Public so the guard can be asserted directly; the seam it protects
  # (Tachikoma's review task) is not reachable from a unit test.
  @doc false
  def ensure_mission_live(op) do
    case GiTF.Missions.get(op.mission_id) do
      {:ok, mission} ->
        status = Map.get(mission, :status)

        if status in GiTF.Missions.terminal_phases(),
          do: {:error, {:mission_terminal, status}},
          else: :ok

      _ ->
        {:error, :mission_not_found}
    end
  end

  @doc """
  Spawns a fix ghost in the same worktree as the failed op.

  The fix ghost receives a prompt with all accumulated fix context
  (prior attempts, failures, feedback) so it can iterate rather than
  start from scratch.

  Returns `{:ok, fix_op}` or `{:error, reason}`.
  """
  @spec request_fix(String.t(), String.t(), map(), FixContext.t()) ::
          {:ok, map()} | {:error, term()}
  def request_fix(op_id, shell_id, failures, %FixContext{} = fix_ctx) do
    with {:ok, op} <- GiTF.Ops.get(op_id),
         # A fix op on a finished mission is an orphan from birth: nothing
         # schedules it, nothing merges it, and it sits "pending" on the
         # mission page forever (msn-0434e9, op-8ff3bc).
         :ok <- ensure_mission_live(op),
         # A fix ghost can only fix CODE. Handing one an infrastructure
         # failure ("TOOL MISSING", exit 126/127) gives it nothing
         # actionable — run 7's quality fix ghost, prompted with exactly
         # that, invented an out-of-scope UI control instead and cost the
         # mission its whole validation budget.
         :ok <- ensure_code_failure(op_id, failures),
         # Single fix lineage: quality-lane fixes defer to any in-flight fix
         # op (either lane). Run 14's quality lane built a competing
         # marker-laden branch lineage in parallel with the validation
         # lane's fully reconciled one — the mission then validated the
         # wrong lineage until its budget died. The next quality gate
         # re-derives anything the in-flight fix doesn't cover.
         false <- GiTF.Ops.worktree_writer_in_flight?(op.mission_id),
         {:ok, shell} <- resolve_fix_shell(op, shell_id) do
      # Build prompt with accumulated history
      feedback = build_fix_prompt(op, failures, fix_ctx)

      # Record this attempt
      fix_ctx = FixContext.record_attempt(fix_ctx, :quality_gate, op_id, failures, feedback)

      # Persist the incremented context onto the ORIGINAL op, not only the
      # new fix op. load_fix_context reads the failing op's own record; when
      # the context lived solely on the (completed) fix ops, every fresh
      # failure of the origin restarted at attempt 1 — exhausted?/1 could
      # never fire, and msn-8933dc ran 12 identical fix cycles against an
      # environmental failure with no cap in sight.
      persist_context_on_origin(fix_ctx)

      # Create fix op
      fix_title = "Fix quality issues (attempt #{fix_ctx.attempt})"

      case GiTF.Ops.create(%{
             title: fix_title,
             description: feedback,
             mission_id: op.mission_id,
             sector_id: op.sector_id,
             phase_job: false,
             skip_verification: false,
             fix_context: FixContext.to_map(fix_ctx),
             fix_of: fix_ctx.original_op_id,
             target_files: op[:changed_files] || []
           }) do
        {:ok, fix_op} ->
          # Spawn in the same worktree
          case GiTF.gitf_dir() do
            {:ok, gitf_root} ->
              case GiTF.Ghosts.spawn_in_worktree(
                     fix_op.id,
                     shell.id,
                     op.sector_id,
                     gitf_root
                   ) do
                {:ok, _ghost} ->
                  {:ok, fix_op}

                {:error, reason} ->
                  Logger.warning(
                    "Togusa: worktree spawn failed, falling back: #{inspect(reason)}"
                  )

                  {:ok, fix_op}
              end

            _ ->
              {:ok, fix_op}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      true ->
        Logger.info(
          "Togusa: fix op already in flight for op #{op_id}'s mission — deferring quality fix"
        )

        {:error, :fix_in_flight}

      error ->
        error
    end
  end

  defp ensure_code_failure(op_id, failures) do
    exit_code = failures[:exit_code] || failures["exit_code"]

    output =
      [failures[:output], failures["output"]]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")
      |> String.downcase()

    if exit_code in [126, 127] or String.contains?(output, "tool missing on host") do
      Logger.warning(
        "Togusa: op #{op_id} failure is infrastructure (exit #{inspect(exit_code)}) — refusing to spawn a code-fix ghost"
      )

      {:error, :infra_failure}
    else
      :ok
    end
  end

  # The fix ghost must inherit the CANONICAL worktree — the chain tip's
  # shell (GiTF.Validation.canonical_impl_shell/1; fix ops excluded from
  # selection because they adopt older shells and would drag the target
  # backward — run 17's re-implementation spiral). The failed op's own
  # shell is only a fallback.
  defp resolve_fix_shell(op, fallback_shell_id) do
    with {:ok, mission} <- GiTF.Missions.get(op.mission_id),
         %{} = shell <- GiTF.Validation.canonical_impl_shell(mission) do
      {:ok, shell}
    else
      _ -> GiTF.Shell.get(fallback_shell_id)
    end
  end

  # Fire-and-forget: a failed persist must not block the fix cycle, but it
  # is logged — attempt accounting silently resetting is how loops hide.
  defp persist_context_on_origin(%FixContext{original_op_id: origin_id} = fix_ctx)
       when is_binary(origin_id) do
    case GiTF.Archive.update(:ops, origin_id, fn op ->
           Map.put(op, :fix_context, FixContext.to_map(fix_ctx))
         end) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Togusa: could not persist fix context on origin #{origin_id}: #{inspect(reason)}"
        )
    end
  end

  defp persist_context_on_origin(_), do: :ok

  # -- Agent Profile Learning ------------------------------------------------

  @doc """
  Learns from a verification failure and improves the sector's agent profile.

  Extracts failure patterns and appends learned anti-patterns to the
  sector's `.claude/agents/*.md` files. Called by both Tachikoma (quality
  gate failures) and the orchestrator (goal fulfillment failures).
  """
  @spec learn_from_failure(String.t(), map()) :: :ok
  def learn_from_failure(op_id, failures) do
    with {:ok, op} <- GiTF.Ops.get(op_id),
         sector when not is_nil(sector) <- GiTF.Archive.get(:sectors, op.sector_id),
         true <- is_binary(sector.path) do
      analysis = build_failure_analysis(failures, op)
      improve_agent_profile(sector.path, analysis, op)
    end

    :ok
  rescue
    e ->
      Logger.debug("Togusa.learn_from_failure failed for op #{op_id}: #{Exception.message(e)}")
      :ok
  end

  # -- Fix Prompt Builder ----------------------------------------------------

  @doc """
  Builds a comprehensive fix prompt incorporating:
  - Original op context
  - Current failure details
  - Full fix history from prior attempts
  - Instructions for iterating in the same worktree
  """
  @spec build_fix_prompt(map(), map(), FixContext.t()) :: String.t()
  def build_fix_prompt(op, failures, %FixContext{} = fix_ctx) do
    sections = [
      "# Fix Required\n",
      "## Original Task\n",
      String.slice(op[:title] || op[:description] || "", 0, 500),
      "",
      "## Current Failures\n",
      format_quality_failures(failures),
      ""
    ]

    # Add prior attempt history if this isn't the first fix
    history_section = FixContext.format_for_prompt(fix_ctx)

    sections =
      if history_section != "" do
        sections ++ [history_section, ""]
      else
        sections
      end

    changed_files = op[:changed_files] || []

    sections =
      if changed_files != [] do
        sections ++ ["## Files Changed\n", Enum.join(changed_files, ", "), ""]
      else
        sections
      end

    instructions = """
    ## Instructions

    You are working in the SAME worktree with your previous changes still present.

    1. Review the failures above carefully
    2. Read the specific files mentioned to understand what needs to change
    3. RECONCILE, don't duplicate: when a failure says something is "missing",
       FIRST search for an existing implementation under a different name,
       field, or location. If one exists, RENAME or REWIRE it — never add a
       second definition. Duplicate struct fields and functions are compile
       errors. Grep before you add.
    4. Make the minimal fixes needed to address each issue
    5. NEVER modify dependency manifests (package.json, package-lock.json,
       Cargo.toml, Cargo.lock, mix.exs deps) unless the task explicitly
       requires it. Dependency vulnerabilities are handled by separate
       maintenance missions — bumping them here is out of scope.
    6. Verify your fixes are correct (run tests/build if available)
    7. Commit your changes with a clear message
    """

    Enum.join(sections, "\n") <> "\n" <> instructions
  end

  # -- Private ---------------------------------------------------------------

  defp format_quality_failures(failures) when is_map(failures) do
    lines = []

    lines =
      case failures[:static_issues] do
        n when is_integer(n) and n > 0 -> lines ++ ["- Static analysis: #{n} issue(s)"]
        _ -> lines
      end

    # Security findings are deliberately OMITTED from fix prompts: they're
    # advisory (see AuditContract) and mentioning them nudged fix ghosts
    # into out-of-scope dependency bumps.

    lines =
      case failures[:proof_of_test] do
        :fail ->
          lines ++ ["- Proof of test: FAILED (no test execution detected or 0 files changed)"]

        _ ->
          lines
      end

    lines =
      case failures[:output] do
        msg when is_binary(msg) and msg != "" ->
          lines ++ ["- Validation output: #{String.slice(msg, 0, 300)}"]

        _ ->
          lines
      end

    lines =
      case failures[:status] do
        "failed" -> lines ++ ["- Overall status: FAILED"]
        _ -> lines
      end

    if lines == [], do: "No specific quality failures recorded.", else: Enum.join(lines, "\n")
  end

  defp format_quality_failures(_), do: "No specific quality failures recorded."

  defp build_failure_analysis(nil, op) do
    %{
      type: :unknown,
      root_cause: "Verification failed for: #{op[:title]}",
      suggestions: ["Ensure changes pass all quality gates before completion"]
    }
  end

  defp build_failure_analysis(failures, _op) when is_map(failures) do
    %{
      type: Map.get(failures, :failure_type, :unknown),
      root_cause: Map.get(failures, :root_cause, Map.get(failures, :output, "Unknown")),
      suggestions: Map.get(failures, :suggestions, [])
    }
  end

  defp build_failure_analysis(_, op), do: build_failure_analysis(nil, op)

  defp improve_agent_profile(sector_path, analysis, op) do
    alias GiTF.AgentProfile.FailureModes

    agents_dir = Path.join(sector_path, ".claude/agents")

    if File.dir?(agents_dir) do
      agents_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.each(fn filename ->
        path = Path.join(agents_dir, filename)
        content = File.read!(path)
        existing_modes = parse_existing_learned_modes(content)

        failure_analysis = build_failure_analysis(analysis, op)

        case FailureModes.learn_from_failure(failure_analysis, existing_modes) do
          {:ok, mode} ->
            section_header =
              if not String.contains?(content, "## Lessons Learned") do
                "\n\n## Lessons Learned\n\n"
              else
                "\n"
              end

            learned_text = FailureModes.format_learned_mode(mode)
            File.write!(path, content <> section_header <> learned_text)

          :skip ->
            :ok
        end
      end)

      Logger.info("Togusa: improved agent profile at #{sector_path} with failure lesson")
    end
  rescue
    e -> Logger.debug("Agent profile improvement failed: #{Exception.message(e)}")
  end

  defp parse_existing_learned_modes(content) do
    ~r/### LEARNED: (\S+) \(from failure\)/
    |> Regex.scan(content)
    |> Enum.map(fn [_, name] ->
      # Names scraped from AI-generated markdown — bound atom creation.
      key = GiTF.SafeAtom.intern!(String.downcase(name), :unknown_mode)
      %{key: key, name: name, description: "", severity: :high}
    end)
  end
end
