defmodule GiTF.Major.PhasePrompts do
  @moduledoc """
  Pure functions that build prompts for each orchestration phase.

  Each prompt provides context from prior phases and specifies the exact
  JSON output format expected. Phase ghosts are instructed to output ONLY
  a JSON object fenced in ```json blocks.
  """

  @doc """
  Builds the triage phase prompt.

  Deliberately short — goal is ~30s execution, not a deep analysis. Later
  phases (when not skipped) do the deep work.
  """
  @spec triage_prompt(map(), map() | nil) :: String.t()
  def triage_prompt(mission, sector) do
    external_resources = extract_external_resources(mission.goal)

    """
    # Triage Phase

    Classify this mission's complexity and decide which pipeline phases are
    needed. Do NOT fully implement or deeply analyze.

    **Goal**: #{mission.goal}

    **Codebase location**: #{sector_path(sector)}

    ## Instructions

    1. Fetch any external resources in the goal FIRST:#{external_resources}
    2. Briefly scan for: goal scope, files likely affected, cross-cutting
       concerns (auth, migrations, schemas, infrastructure).
    3. Classify complexity:
       - `trivial`: single-file string/config change; no logic change
       - `simple`: single-file logic change OR focused ≤3-file refactor
       - `moderate`: multi-file logic change, new feature in existing
         architecture, no cross-cutting concerns
       - `complex`: architectural work, schema changes, cross-cutting
         concerns, new subsystem, or unclear requirements
    4. **You MUST find the target files before emitting your reply.** For
       `trivial` or `simple` missions, this is your single most important
       task in this phase — do it before anything else after step 1.
       How to do it:
         a. Use `Glob` / `Grep` / `Read` tools NOW to search the repo
            for literal strings from the goal (labels, function names,
            error messages). Try case-insensitive (`grep -i`) and
            multiple variants — bug report titles often have typo'd
            casing that doesn't match the code.
         b. Follow any path hints in screenshots, stack traces, or issue
            bodies.
         c. Emit sector-relative paths (e.g. `src/components/Foo.tsx`)
            as #{fld("target_files", "F lines")}.
       The target files MUST be non-empty for `trivial`/`simple`
       classifications. If you cannot find any file, downgrade the
       classification to `moderate` so research runs — do NOT emit an
       an empty target-file list with a trivial/simple classification.
       For `moderate`/`complex`, the target files may be empty or partial —
       research will fill it in.
    5. **Preflight — evidence first, then flag.** Do these steps IN
       ORDER. Do NOT set `bug_reproducible` before you have written
       `bug_evidence`.

         a. Read the identified target files.

         b. Write `bug_evidence` — ONE sentence describing WHAT YOU SAW
            in the file, in literal terms. Required for every mission,
            including feature requests.

            Good examples:
              - "DiffViewer.tsx:1665 has `<button onClick={collapseAllLow}>Collapse low</button>` — the reported bad state IS present."
              - "Searched DiffViewer.tsx for 'Collapse Low' (case-insensitive) and 'collapseAllLow' — both absent. Line 1664 reads `Collapse All` with `onClick={collapseAll}`. The reported bad state is NOT present."
              - "N/A — feature request, nothing to reproduce."

            Bad examples (DO NOT emit):
              - "" (empty — forbidden)
              - "Bug appears to be present" (no evidence cited)
              - "Contradictory" (no decision)

         c. Derive `bug_reproducible` from the evidence you just wrote:
              - Evidence describes bad state IS present → `true`
              - Evidence describes bad state is NOT present → `false`
                (mission will complete as no-work-needed)
              - Evidence is "N/A — feature request" → `true`

       If your evidence says the bug isn't present but you're inclined
       to set `true` anyway "just in case," STOP. The mission pipeline
       has its own safety nets. Your job here is to state what's
       literally in the file. Trust your own observation.

    Budget: spend no more than 90 seconds on this phase.

    ## Skip policy

    Skip every phase BEFORE the tier your classification starts at:
    `trivial` starts at implementation, `simple` at planning, `moderate` at
    research, `complex` at the full pipeline. Deviate only with explicit
    reasoning. **Validation always runs** regardless of skip flags.

    #{reply_format("triage")}
    """
  end

  defp sector_path(nil), do: "."
  defp sector_path(sector), do: sector.path

  @doc """
  Builds the research phase prompt.

  When `opts[:complexity]` is `"trivial"`, `"simple"`, or `"moderate"`,
  emits a slim prompt with a 60s budget and a minimal schema. Otherwise
  emits the comprehensive audit used for `"complex"` or unhinted missions.

  The complexity hint normally comes from the triage phase's artifact.
  """
  @spec research_prompt(map(), map() | nil, String.t(), keyword()) :: String.t()
  def research_prompt(mission, sector, historical_context \\ "", opts \\ []) do
    complexity = opts |> Keyword.get(:complexity) |> GiTF.Triage.complexity_from_string()

    case complexity do
      c when c in [:trivial, :simple, :moderate] ->
        lightweight_research_prompt(mission, sector, historical_context)

      _ ->
        comprehensive_research_prompt(mission, sector, historical_context)
    end
  end

  defp lightweight_research_prompt(mission, sector, historical_context) do
    external_resources = extract_external_resources(mission.goal)

    """
    # Research Phase (lightweight)

    Triage has already classified this mission as low-to-moderate complexity.
    Produce just enough codebase context for downstream phases to work.
    Do NOT do a comprehensive audit.

    **Goal**: #{mission.goal}

    **Codebase location**: #{sector_path(sector)}

    ## Instructions

    1. Fetch any external resources referenced in the goal:#{external_resources}
    2. Identify the 2-5 files most relevant to the goal. Do NOT enumerate the
       whole repo.
    3. Note any external context (issue/PR body) that changes the requirements.

    Budget: spend no more than 60 seconds on this phase.
    #{if historical_context != "", do: "\n" <> historical_context <> "\n", else: ""}
    #{reply_format("research", lightweight: true)}
    """
  end

  defp comprehensive_research_prompt(mission, sector, historical_context) do
    external_resources = extract_external_resources(mission.goal)

    """
    # Research Phase

    You are a codebase analyst. Your task is to thoroughly research and understand the
    codebase to inform the implementation of the following goal:

    **Goal**: #{mission.goal}

    **Codebase location**: #{sector_path(sector)}

    ## Instructions

    1. **Fetch any external resources** referenced in the goal FIRST — this is critical
       to understanding what needs to be built#{external_resources}
    2. Read key files to understand the project architecture
    3. Identify coding patterns, conventions, and style
    4. Understand the tech stack and dependencies
    5. Identify test setup and testing conventions
    7. **Assess complexity**: Based on your research, determine if this goal can be
       completed by a single ghost agent in a single session (low) or if it requires
       coordinated steps across multiple components (high).
    #{if historical_context != "", do: "\n" <> historical_context <> "\n", else: ""}
    #{reply_format("research")}
    Be thorough but concise. Focus on information relevant to achieving the goal.
    """
  end

  # Detect GitHub URLs in the goal and generate fetch instructions
  defp extract_external_resources(goal) do
    github_issues = Regex.scan(~r{https?://github\.com/([^/]+/[^/]+)/issues/(\d+)}, goal)
    github_prs = Regex.scan(~r{https?://github\.com/([^/]+/[^/]+)/pull/(\d+)}, goal)

    instructions = []

    instructions =
      instructions ++
        Enum.map(github_issues, fn [_url, repo, number] ->
          "   - Run `gh issue view #{number} --repo #{repo}` to fetch the issue description"
        end)

    instructions =
      instructions ++
        Enum.map(github_prs, fn [_url, repo, number] ->
          "   - Run `gh pr view #{number} --repo #{repo}` to fetch the PR description"
        end)

    if instructions == [] do
      ""
    else
      "\n" <> Enum.join(instructions, "\n")
    end
  end

  @doc """
  Builds the requirements phase prompt.

  Produces structured requirements with testable acceptance criteria from
  the goal and research findings.
  """
  @spec requirements_prompt(map(), map(), String.t()) :: String.t()
  def requirements_prompt(mission, research_artifact, historical_context \\ "") do
    # The EARS fields (ears_pattern/trigger/response) are strictly additive:
    # every downstream consumer — the design and validation prompts, the
    # DesignDeck question slides, Helpers.requirement_index, the design
    # artifact's requirement_mapping — reads requirements as {"id",
    # "description"} maps, so "description" must remain the full assembled
    # EARS sentence rather than being split across the new fields.

    """
    # Requirements Phase

    You are a requirements analyst. From the goal and codebase research below,
    produce structured requirements with testable acceptance criteria.

    **Goal**: #{mission.goal}

    #{artifacts_block([{"Codebase Research", "research", research_artifact}])}
    ## Instructions

    1. Break the goal into specific functional requirements, each written as
       a single EARS statement (syntax below)
    2. Each requirement must have testable acceptance criteria
    3. Identify non-functional requirements (performance, security, etc.)
    4. Note constraints from the existing codebase
    5. Explicitly list what is OUT of scope
    6. Name the work in 3-5 words, as a human would title the pull request —
       the feature or fix itself, not the files it touches

    ## EARS Syntax (Easy Approach to Requirements Syntax)

    Every requirement uses one of five patterns:

    - **ubiquitous** — always active, no trigger: "The system SHALL log every
      authentication attempt."
    - **event** — response to a trigger: "WHEN a user submits invalid
      credentials, the system SHALL display an error message."
    - **state** — active during a state: "WHILE a deployment is in progress,
      the system SHALL queue incoming requests."
    - **unwanted** — handling a failure or unwanted condition: "IF the
      configuration file is missing, THEN the system SHALL fall back to
      built-in defaults."
    - **optional** — applies only when a feature is present: "WHERE SSO is
      configured, the system SHALL redirect login to the identity provider."

    Requirements must be testable and singular: exactly ONE SHALL per
    requirement, no "and" chains — split compound behavior into separate
    requirements.

    #{if historical_context != "", do: "\n" <> historical_context <> "\n", else: ""}
    #{reply_format("requirements")}
    Keep requirements minimal and focused. Do not add unnecessary scope.
    """
  end

  @doc """
  Builds the design phase prompt.

  Maps requirements to implementation approach with specific file changes.
  """
  @spec design_prompt(map(), map(), map(), String.t(), String.t()) :: String.t()
  def design_prompt(
        mission,
        requirements,
        research,
        extra_instructions \\ "",
        historical_context \\ ""
      ) do
    instructions = """
    1. Map each requirement to a specific implementation approach
    2. List exact files to create or modify
    3. Define API contracts and interfaces
    4. Identify component dependencies
    5. Note implementation risks
    """

    final_instructions =
      if extra_instructions != "",
        do: instructions <> "#{extra_instructions}\n",
        else: instructions

    """
    # Technical Design Phase

    You are a software architect. Design the implementation approach for
    the following requirements, given the codebase research.

    **Goal**: #{mission.goal}

    #{artifacts_block([{"Codebase Research", "research", research}, {"Requirements", "requirements", requirements}])}
    ## Instructions

    #{final_instructions}
    #{if historical_context != "", do: historical_context <> "\n\n", else: ""}#{reply_format("design")}
    """
  end

  @doc """
  Builds the design prompt with review feedback for redesign iterations.
  """
  @spec design_prompt_with_feedback(map(), map(), map(), map(), String.t(), String.t()) ::
          String.t()
  def design_prompt_with_feedback(
        mission,
        requirements,
        research,
        review,
        extra_instructions \\ "",
        historical_context \\ ""
      ) do
    base = design_prompt(mission, requirements, research, extra_instructions, historical_context)

    base <>
      """

      ## IMPORTANT: Previous Review Feedback

      Your previous design was reviewed and issues were found. Address ALL of
      the following feedback in your revised design:

      #{artifacts_block([{"Review", "review", review}])}
      Pay special attention to any coverage gaps or high-severity issues.
      """
  end

  @doc """
  Builds the review phase prompt.

  Cross-validates design against requirements.
  """
  @spec review_prompt(map(), map(), map(), map(), String.t()) :: String.t()
  def review_prompt(mission, designs, requirements, research, historical_context \\ "") do
    # `designs` is a name → design map (DesignBoard.collect_design_variants/1).
    multi_design? = map_size(designs) > 1

    design_sections =
      if multi_design? do
        # Multiple design variants — pass only structural keys to reduce token load
        designs
        |> Enum.sort_by(fn {name, _} -> name end)
        |> Enum.map(fn {name, design} ->
          {"Design: #{String.upcase(name)}", "design", design, view: :brief}
        end)
      else
        # Single design — pass in full since there's no comparison overhead
        design = designs |> Map.values() |> List.first()
        [{"Technical Design", "design", design}]
      end

    selection_instruction =
      if multi_design? do
        """
        6. **Select the best design**: Compare the designs and select the one that best
           balances completeness, simplicity, and feasibility. Set `selected_design` to
           its name (minimal, normal, or complex). Prefer "normal" unless there's a
           strong reason to pick another.
        """
      else
        ""
      end

    """
    # Design Review Phase

    You are a technical reviewer. #{if multi_design?, do: "Compare the design variants and select the best one, then cross-validate", else: "Cross-validate the design"} against the requirements. Check for coverage gaps, feasibility issues, and risks.

    **Goal**: #{mission.goal}

    #{artifacts_block([{"Codebase Research", "research", research}, {"Requirements", "requirements", requirements}] ++ design_sections)}
    #{if historical_context != "", do: "\n" <> historical_context <> "\n", else: ""}
    ## Instructions

    1. Verify every functional requirement has a design component
    2. Check that the design is feasible given the codebase architecture
    3. Identify any gaps, inconsistencies, or missing pieces
    4. Assess implementation risks
    5. Approve or reject with specific feedback. A requirement that says to
       ask, consult, or let the operator choose is SATISFIED by an answer
       under OPERATOR DECISIONS above — the answer is the auditable record
       (who, when, what). Never reject a design for building to a decision
       the operator has already made, and never demand the question be
       asked again.
    #{selection_instruction}
    #{reply_format("review", multi_design: multi_design?)}
    Set #{fld("approved", "ok")} to #{fld("false", "n")} if there are any high-severity issues or
    uncovered requirements. Be rigorous but practical.
    """
  end

  @doc false
  # Complexity-proportional decomposition. The run-13→18 defect catalog was
  # handoff failures, never capability failures — and the lesson it taught
  # is narrower than the rule it produced. Handoffs WITHIN a surface (two
  # ops relaying edits to the same files) caused every one of those
  # deaths; handoffs BETWEEN surfaces (Rust op, TS op, disjoint files)
  # merge trivially, and serializing them only wastes wall-clock. So:
  # trivial/simple stay one op — splitting one-session work adds
  # coordination without capability. Moderate and complex split along
  # ownership boundaries only, per the rules in the planning prompt.
  # Moderate was in the one-op bucket until 2026-08-25; the failures that
  # justified that (conflict-abort consolidation, canonical-shell ranking,
  # retry DAG orphans) are fixed, and scratch-worktree merges with a
  # working AI resolution tier make the remaining risk recoverable. The
  # next multi-surface mission run is this change's acceptance test.
  def decomposition_instructions(mission) do
    if single_op_scope?(mission) do
      """
      1. Produce EXACTLY ONE op that implements the COMPLETE feature end to
         end — backend, frontend, wiring, regenerated bindings, everything.
         This task fits a single agent working in one worktree; splitting it
         adds coordination cost without adding capability.
      2. The op description must be a complete, ordered implementation brief.
      """
    else
      """
      1. Split ops along FILE/SURFACE OWNERSHIP boundaries: one op per
         independent deliverable whose target files no other op touches.
         Two ops naming the same file MUST be linked by a dependency;
         ops with disjoint files and no data dependency MUST NOT depend on
         each other — they will execute as parallel ghosts.
      2. Never split what one agent can complete in a session; each op must
         be completable by a single agent in one session.
      """
    end
  end

  @doc false
  def single_op_scope?(mission) do
    complexity =
      case GiTF.Missions.get_artifact(mission.id, "triage") do
        %{"complexity" => c} when is_binary(c) -> c
        _ -> nil
      end

    complexity in ["trivial", "simple"]
  rescue
    _ -> false
  end

  @doc """
  Builds the planning phase prompt.

  Generates ordered ops with dependencies from the validated design.
  """
  @spec planning_prompt(map(), map(), map(), map(), String.t()) :: String.t()
  def planning_prompt(mission, design, requirements, review, historical_context \\ "") do
    # Extract only actionable review feedback, not the full artifact
    review_sections =
      if is_map(review) do
        issues = Map.get(review, "issues", [])
        selected = Map.get(review, "selected_design")

        # The reviewer's statement of which requirement no component
        # delivers is the one thing the planner must not lose.
        uncovered = GiTF.Phases.Review.uncovered(review)

        condensed =
          %{
            "selected_design" => selected,
            "issues" => issues,
            "uncovered_requirements" => if(uncovered == [], do: nil, else: uncovered),
            "risk_assessment" => Map.get(review, "risk_assessment")
          }
          |> Map.reject(fn {_, v} -> is_nil(v) end)

        [{"Review Feedback", "review", condensed}]
      else
        []
      end

    """
    # Planning Phase

    You are a project planner. Using the validated design and requirements below,
    produce an ordered list of implementation ops with dependencies. Stay grounded
    in the actual codebase — only reference files, patterns, and technologies
    identified in the design. Do NOT introduce new technologies or frameworks
    that aren't already in the project.

    **Goal**: #{mission.goal}

    #{artifacts_block([{"Requirements", "requirements", requirements}, {"Technical Design", "design", design}] ++ review_sections)}
    ## Instructions

    #{decomposition_instructions(mission)}
    - Define clear acceptance criteria derived from requirements
    - Specify target files from the design — these must be real files in the project
    - Never plan an op whose deliverable is a mockup, prototype or preview
      file (`.gitf-mockups/`, `mockups/*.html`, a "design evidence" page).
      Mockups exist only so the design phase can ask the operator a
      question; they are rendered outside the repository and once the
      question is answered they are spent. Plan the chosen option, nothing
      that documents the choosing
    - Set up dependencies (op indices, 0-based)
    - Tag each op with #{fld("requirement_ids", "r")}: the requirement ids THIS op delivers,
      drawn ONLY from the ids in the Requirements artifact above. Every
      functional requirement must be covered by at least one op. State coverage
      honestly — never pad the requirement ids to make coverage look complete
    - Recommend model complexity: "general" for straightforward changes, "thinking" for complex logic
    #{if historical_context != "", do: "\n" <> historical_context <> "\n", else: ""}
    #{reply_format("plan")}
    #{ownership_split_guidance()}
    """
  end

  @doc """
  The planning prompt for a mission that lacks some upstream artifacts —
  the studio/plan-on-demand path in `GiTF.Major.Planner`. `artifacts` is a
  list of `{heading, kind, artifact_or_nil}`; absent ones are skipped.
  """
  @spec partial_planning_prompt(map(), [tuple()], keyword()) :: String.t()
  def partial_planning_prompt(mission, artifacts, opts) do
    present = Enum.reject(artifacts, fn {_h, _k, a} -> is_nil(a) end)

    feedback_section =
      case Keyword.get(opts, :feedback) do
        nil -> ""
        feedback -> "\n## Revision Feedback\n#{feedback}\n"
      end

    """
    # Planning Phase

    You are a project planner. Produce an ordered list of implementation ops.

    **Goal**: #{mission.goal}
    **Project path**: #{Keyword.get(opts, :sector_path, "unknown")}

    #{artifacts_block(present)}
    #{feedback_section}
    #{Keyword.get(opts, :strategy_section, "")}

    ## Instructions

    1. Break the work into discrete, parallelizable ops
    2. Each op should be completable by a single developer in one session
    3. Define clear acceptance criteria
    4. Specify target files where possible
    5. Set up dependencies between ops
    6. Recommend model complexity (general for simple, thinking for complex)

    #{reply_format("plan")}
    #{ownership_split_guidance()}
    """
  end

  # This deliberately re-opens multi-op parallelism: the previous "keep ops
  # minimal (2-4), prefer fewer larger ops" guidance was a defense against
  # run 13, where consolidation ABORTED on the first merge conflict and
  # validation never saw the frontend branch. Consolidation now merges in
  # scratch worktrees with a working AI conflict-resolution tier
  # (2026-08-25), so the residual rule is ownership, not count: same-file
  # parallel ghosts still produce conflicts, and serializing disjoint files
  # still wastes wall-clock. The next mission run is the acceptance test.
  defp ownership_split_guidance do
    """
    Split ops by FILE/SURFACE OWNERSHIP, not by size:

    - Two ops must NOT both list the same target file unless one depends on
      the other. Parallel ghosts editing the same file produce
      merge conflicts — this has killed real mission runs.
    - Ops with disjoint target files and no data dependency must NOT depend
      on each other: they will run as parallel ghosts, and artificial
      serialization of disjoint files wastes wall-clock time.
    - Size each op so a single ghost can complete it in one session.
    - Keep genuinely sequential work sequential via explicit dependencies
      (e.g. an op that consumes an interface another op creates).
    """
  end

  @doc """
  Builds the validation phase prompt.

  Reviews all implementation against original requirements.
  """
  @spec validation_prompt(map(), map() | nil, map() | nil, String.t()) :: String.t()
  def validation_prompt(mission, requirements, planning, historical_context \\ "", opts \\ []) do
    diff_base = Keyword.get(opts, :diff_base, "main")
    changed_files = Keyword.get(opts, :changed_files, [])
    lsp_diagnostics = Keyword.get(opts, :lsp_diagnostics, [])

    changed_files_block =
      case changed_files do
        [] ->
          ""

        files ->
          """

          ## Files the implementation ghost reported changing

          The implementation ghost committed changes to these files on the branch
          your worktree is currently on. Use this as ground truth — if `git diff`
          against `#{diff_base}` shows these files, the implementation landed.

          ```
          #{Enum.join(files, "\n")}
          ```
          """
      end

    lsp_diagnostics_block = render_lsp_diagnostics_block(lsp_diagnostics)
    exec_validation_block = render_exec_validation_block(Keyword.get(opts, :exec_validation))
    infra_notes_block = render_infra_notes_block(Keyword.get(opts, :infra_notes, []))

    accepted_block =
      render_accepted_requirements_block(Keyword.get(opts, :accepted_requirements, []))

    contested_block =
      render_contested_requirements_block(Keyword.get(opts, :contested_requirements, []))

    contested? = contested_block != ""

    # An overruled design review is a live lead for validation: the
    # reviewer's unresolved concern is exactly where the implementation is
    # most likely to fall short of the requirements.
    unresolved_review_block =
      case Keyword.get(opts, :unresolved_review) do
        text when is_binary(text) ->
          """

          ## UNRESOLVED DESIGN REVIEW OBJECTION

          The design review rejected this approach but its redesign budget was
          exhausted, so the mission proceeded anyway. Treat this as a lead, not
          a verdict — check whether the shipped code actually suffers from it:

          #{text}
          """

        _ ->
          ""
      end

    merge_conflicts_block =
      case Keyword.get(opts, :merge_conflicts, []) do
        [] ->
          ""

        notes ->
          # Since incremental merge-and-resolve landed, this channel no
          # longer carries raw marker-file paths (consolidation halts and
          # resolves those before validation ever spawns). What arrives is
          # prose: `UNMERGED BRANCH …` sentences and/or a `POSSIBLE
          # unresolved conflict markers …` adjudication note. Render them
          # as notes to be read literally — the old "these files will not
          # compile" framing contradicted the adjudication note outright.
          """

          ## CONSOLIDATION NOTES

          Consolidating the implementation branches left the following
          conditions. Read each entry LITERALLY and verify it against the
          tree — do not assume more or less than it states:

          ```
          #{Enum.join(notes, "\n")}
          ```

          Entries marked `UNMERGED BRANCH` mean that branch's commits are
          entirely ABSENT from this tree (the merge itself failed) — report
          the missing work as a gap so the fix ghost merges the branch or
          re-applies its changes.

          Entries marked `POSSIBLE unresolved conflict markers` mean the
          marker scan and focused resolution ghosts disagreed — check the
          named files; if real markers exist, report each as a gap of the
          form "reconcile merge conflict markers in <file>" (both sides are
          wanted work — merge them, never delete one side wholesale); if
          the content is intentional, say so and move on.
          """
      end

    base_moved_block =
      case Keyword.get(opts, :base_moved) do
        %{commits: n, subjects: subjects, files: files} when n > 0 ->
          """

          ## MAIN MOVED WHILE THIS MISSION RAN

          #{n} commit(s) landed on the main branch after this work began. The
          plan above was written against the tree BEFORE them.

          ```
          #{Enum.join(subjects, "\n")}
          ```

          Files they touched:

          ```
          #{Enum.join(files, "\n")}
          ```

          Judge the implementation against the code as it is NOW, not as the
          plan assumed it would be. In particular, report a gap when this work
          duplicates something those commits already added, contradicts a
          convention they established, or calls an interface they changed —
          even if it compiles and every requirement is otherwise met. A clean
          merge is not evidence that the plan survived.
          """

        _ ->
          ""
      end

    """
    # Validation Phase

    You are a QA validator. Review all implementation work against the
    original requirements and planned ops.

    **Goal**: #{mission.goal}

    #{artifacts_block([{"Requirements", "requirements", requirements}, {"Planned Ops", "plan", planning}])}#{changed_files_block}#{accepted_block}#{contested_block}#{lsp_diagnostics_block}#{exec_validation_block}#{infra_notes_block}#{base_moved_block}#{merge_conflicts_block}#{unresolved_review_block}
    ## Instructions

    Your worktree is on the implementation branch. The implementation's
    commits are already in HEAD — a plain `git diff` with no ref will show
    NOTHING because there are no uncommitted changes. To see what the
    implementation actually did, diff against the base branch:

        git_diff(ref: "#{diff_base}")

    Steps:

    1. Run `git_diff(ref: "#{diff_base}")` to inspect the implementation's changes.
    2. Check each functional requirement was implemented.
    3. Verify per-requirement coverage: each planned op's #{fld("requirement_ids", "r")}
       declares which requirements that op delivers — use them as the map of
       intent, then confirm the diff actually delivers each one.
    4. Review the code changes for correctness.
    5. Verify acceptance criteria are met.
    6. Run tests if available.
    7. Identify any gaps between requirements and implementation.

    **You are NOT here to modify code.** If a requirement is missing, report
    it in #{fld("gaps", "gap")}; a fix ghost will handle the repair in a later step.
    #{if historical_context != "", do: "\n" <> historical_context <> "\n", else: ""}
    #{reply_format("validation", contested: contested?)}
    #{fld("uncovered_requirements", "unc")} lists requirement ids that NO op claimed in its
    #{fld("requirement_ids", "r")} AND for which no evidence shows the work was delivered
    anyway. Use #{fld("[]", "-")} when every requirement is covered.

    Set #{fld("overall_verdict", "verdict")} to #{fld("\"fail\"", "fail")} if any must-have requirements are not met.
    """
  end

  # The ratchet. Without it every fix round re-verified all 16
  # requirements, and the last two runs hit the fix cap re-proving
  # requirements a previous validator had already accepted — the budget
  # was spent on litigation, not on the one open gap.
  defp render_accepted_requirements_block([]), do: ""

  defp render_accepted_requirements_block(ids) when is_list(ids) do
    """

    ## ALREADY ACCEPTED — do not re-litigate

    An earlier validation round verified these requirement ids and
    accepted them. They are SETTLED. Report each in `requirements_met`
    with `met: true` and the evidence "accepted in an earlier validation
    round", and spend this round entirely on the requirements NOT listed
    here:

    ```
    #{Enum.join(ids, ", ")}
    ```

    Two things are never settled and MUST be re-checked every round
    regardless of this list: the project's build/typecheck must pass, and
    the execution validation above is ground truth. If either fails, the
    verdict is `fail` — even when every requirement is accepted.
    """
  end

  # The counter-ratchet. msn-978954's validator read the same code its
  # parent's validator had already judged short on FR-5, called it met,
  # and filed the identical concern in `gaps` as "minor, non-blocking" —
  # because nothing in the prompt made it confront the standing verdict.
  # The floor is quoted from `GiTF.Phases.Validation` rather than repeated
  # here: a prompt that advertises a threshold the gate does not enforce
  # is worse than no prompt at all.
  @doc """
  Why an earlier run of this work was sent back at approval, from the
  mission's `rejection_notes` (inherited across a resume). Empty when
  there are none.
  """
  @spec render_rejection_notes_block(map()) :: String.t()
  def render_rejection_notes_block(mission) do
    case Map.get(mission, :rejection_notes) do
      [_ | _] = notes ->
        lines =
          Enum.map_join(notes, "\n", fn n ->
            meta = Enum.filter([n["rejected_by"], n["rejected_at"]], &is_binary/1)
            "- #{n["reason"]}" <> if(meta == [], do: "", else: " (#{Enum.join(meta, ", ")})")
          end)

        """
        ## REJECTED AT APPROVAL — an earlier run of this work

        The operator reviewed an earlier run's result and sent it back for
        these reasons. They are requirements now: whatever you produce must
        answer every one of them, and a validator must check that it does.

        #{lines}
        """

      _ ->
        ""
    end
  end

  defp render_contested_requirements_block([]), do: ""

  defp render_contested_requirements_block(entries) when is_list(entries) do
    floor = GiTF.Phases.Validation.rebuttal_min_chars()

    lines =
      entries
      |> Enum.filter(&(is_map(&1) and is_binary(&1["req_id"])))
      |> Enum.map_join("\n", fn entry -> "- #{entry["req_id"]}: #{entry["reason"]}" end)

    if lines == "" do
      ""
    else
      """

      ## PREVIOUSLY JUDGED UNMET — a flip requires a rebuttal

      An earlier validation round — this mission, or the lineage it was
      resumed from — judged these requirements UNMET, for the reasons
      quoted:

      ```
      #{lines}
      ```

      A verdict may not flip on amnesia. To report any of these with
      `met: true`, that entry MUST also carry a `rebuttal` field of at
      least #{floor} characters that either names the specific code change
      which answers the quoted reason, or explains concretely why the prior
      verdict was wrong. `met: true` here WITHOUT such a rebuttal is
      mechanically downgraded to unmet by the factory and fails the round —
      and that includes marking it met while filing the same concern in
      `gaps` as minor or non-blocking.

      If the quoted reason still stands, say so. `met: false` with the
      evidence is the honest answer and costs you nothing.
      """
    end
  end

  # The factory could not obtain its own read on the tree this round.
  # Said plainly so the validator does not mistake missing ground truth
  # for passing ground truth.
  defp render_infra_notes_block([]), do: ""

  defp render_infra_notes_block(notes) when is_list(notes) do
    """

    ## GROUND TRUTH UNAVAILABLE (infrastructure)

    The factory could not run the sector's validation command this round:

    ```
    #{Enum.join(notes, "\n")}
    ```

    This is a HOST problem, not a code problem. Absence of ground truth is
    NOT evidence that the build passes — judge the diff on its merits, and
    say in `summary` that execution validation was unavailable so the
    verdict is read as provisional.
    """
  end

  # Renders error-severity LSP diagnostics as ground-truth context.
  # Result of running the sector's validation_command against the
  # implementation worktree, injected as ground truth the LLM must honor.
  defp render_exec_validation_block(nil), do: ""

  defp render_exec_validation_block({:pass, command}) do
    """

    ## Execution validation: PASSED

    The sector's validation command ran successfully in the implementation
    worktree — the change compiles/passes its checks:

        #{command}

    This confirms mechanical soundness only; still review the diff against
    the requirements.
    """
  end

  defp render_exec_validation_block({:pre_existing, command, output, baseline_output}) do
    tail = fn text ->
      if String.length(text) > 1500,
        do: "…(truncated)…\n" <> String.slice(text, -1500, 1500),
        else: text
    end

    """

    ## Execution validation: FAILS — and ALSO FAILS ON THE BASE COMMIT (pre-existing)

    The sector's validation command was executed in the implementation
    worktree and failed. The factory then ran the SAME command on the
    commit this work branched from, in a clean scratch worktree, and it
    failed there too. The breakage predates this mission and is NOT
    attributable to the implementation; the operator has been alerted to
    fix the sector.

    Consequences for your verdict:
    - Do NOT mark any requirement unmet on account of this failure, and do
      NOT report it as a gap. A requirement that the build or tests pass
      is judged on the implementation's OWN changes only: cite the
      pre-existing failure in its evidence and mark it met unless the diff
      itself introduces a further failure.
    - Judge everything else from the diff as usual.

        #{command}

    Implementation worktree:

    ```
    #{tail.(output)}
    ```

    Base commit (clean scratch worktree):

    ```
    #{tail.(baseline_output)}
    ```
    """
  end

  defp render_exec_validation_block({:fail, command, output}) do
    tail =
      if String.length(output) > 4000,
        do: "…(truncated)…\n" <> String.slice(output, -4000, 4000),
        else: output

    """

    ## Execution validation: FAILED

    The sector's validation command was executed in the implementation
    worktree and FAILED. This is ground truth from a real execution — it
    overrides anything the diff appears to show. Your verdict MUST be
    `fail`, and you MUST include a gap quoting the relevant part of this
    output:

        #{command}

    ```
    #{tail}
    ```
    """
  end

  # Skipped (empty string) when no errors — keeps the prompt slim.
  defp render_lsp_diagnostics_block([]), do: ""

  defp render_lsp_diagnostics_block(file_diagnostics) when is_list(file_diagnostics) do
    body =
      file_diagnostics
      |> Enum.map_join("\n\n", fn {file, diags} ->
        "### `#{file}`\n\n" <>
          Enum.map_join(diags, "\n", &format_diagnostic/1)
      end)

    """

    ## LSP diagnostics on the changed files

    The language server reported these compile-time errors on the
    implementation's changes. If any are present, the verdict should
    almost certainly be `fail` — the impl ghost shipped broken code.

    #{body}
    """
  end

  defp render_lsp_diagnostics_block(_), do: ""

  defp format_diagnostic(diag) do
    line = get_in(diag, ["range", "start", "line"]) || 0
    char = get_in(diag, ["range", "start", "character"]) || 0
    severity = severity_label(Map.get(diag, "severity", 1))
    source = Map.get(diag, "source", "lsp")
    msg = Map.get(diag, "message", "") |> String.split("\n") |> List.first()
    "- [#{severity}] L#{line + 1}:#{char + 1} (#{source}) #{msg}"
  end

  defp severity_label(1), do: "error"
  defp severity_label(2), do: "warning"
  defp severity_label(3), do: "info"
  defp severity_label(4), do: "hint"
  defp severity_label(_), do: "?"

  @doc """
  Returns 3 {focus, prompt} tuples for parallel simplify agents.
  Each agent reviews changed files with a different lens.
  """
  def simplify_prompts(mission, repo_path, changed_files) do
    files_list =
      if changed_files != [], do: Enum.join(changed_files, "\n"), else: "(no files tracked)"

    location = repo_path || "(unknown)"

    [
      {"reuse",
       """
       # Code Reuse Review

       You are a code reuse specialist. Review the changed files for duplicated logic,
       repeated patterns, and missed abstractions.

       **Goal**: #{mission.goal}
       **Codebase**: #{location}

       ## Changed Files
       #{files_list}

       ## Instructions

       1. Read each changed file
       2. Search the codebase for similar patterns that could be consolidated
       3. Identify duplicated logic across files
       4. Suggest extractions into shared helpers/modules where beneficial
       5. **Apply fixes directly** — don't just report, fix the code

       ## Output Format

       Output ONLY a JSON object in a ```json fence:

       ```json
       {
         "issues_found": 0,
         "issues_fixed": 0,
         "changes": [
           {
             "file": "path/to/file",
             "type": "extracted_helper",
             "description": "What was changed and why"
           }
         ],
         "summary": "Brief summary of reuse improvements"
       }
       ```
       """},
      {"quality",
       """
       # Code Quality Review

       You are a code quality specialist. Review the changed files for readability,
       structural problems, and patterns that a senior developer would flag in code review.

       **Goal**: #{mission.goal}
       **Codebase**: #{location}

       ## Changed Files
       #{files_list}

       ## Instructions

       1. Read each changed file
       2. Check naming conventions, function length, clarity
       3. Look for overly complex conditionals, deep nesting, unclear intent
       4. Identify missing error handling at system boundaries
       5. **Apply fixes directly** — don't just report, fix the code

       Do NOT add unnecessary comments, docstrings, or type annotations to code
       that is already clear. Only fix genuine quality issues.

       ## Output Format

       Output ONLY a JSON object in a ```json fence:

       ```json
       {
         "issues_found": 0,
         "issues_fixed": 0,
         "changes": [
           {
             "file": "path/to/file",
             "type": "simplified_logic",
             "description": "What was changed and why"
           }
         ],
         "summary": "Brief summary of quality improvements"
       }
       ```
       """},
      {"efficiency",
       """
       # Efficiency Review

       You are a performance and efficiency specialist. Review the changed files for
       unnecessary iterations, resource waste, and missed optimizations.

       **Goal**: #{mission.goal}
       **Codebase**: #{location}

       ## Changed Files
       #{files_list}

       ## Instructions

       1. Read each changed file
       2. Look for unnecessary iterations, N+1 patterns, redundant computations
       3. Check for resource leaks (unclosed files, connections, etc.)
       4. Identify missed concurrency/batching opportunities
       5. **Apply fixes directly** — don't just report, fix the code

       Do NOT prematurely optimize. Only fix genuine efficiency issues that would
       matter at normal scale.

       ## Output Format

       Output ONLY a JSON object in a ```json fence:

       ```json
       {
         "issues_found": 0,
         "issues_fixed": 0,
         "changes": [
           {
             "file": "path/to/file",
             "type": "removed_n_plus_1",
             "description": "What was changed and why"
           }
         ],
         "summary": "Brief summary of efficiency improvements"
       }
       ```
       """}
    ]
  end

  @doc "Scoring prompt: assess final result across 4 eval dimensions."
  def scoring_prompt(mission, requirements, validation, historical_context \\ "") do
    validation = if is_map(validation), do: validation, else: nil
    op_count = length(Map.get(mission, :ops, []))
    pipeline_mode = Map.get(mission, :pipeline_mode, "full")

    """
    # Final Scoring

    You are a project assessor evaluating ghost agent performance across
    four standardized evaluation dimensions.

    **Goal**: #{mission.goal}
    **Pipeline**: #{pipeline_mode} | **Ops**: #{op_count}

    #{artifacts_block([{"Requirements", "requirements", requirements, view: :brief}, {"Validation Result", "validation", validation}])}
    ## Evaluation Dimensions

    Score each dimension 0-100:

    ### 1. Final Output (40% weight)
    The "What" — accuracy and completeness of the final deliverable.
    - Does the output match the specification?
    - Are all requirements met?
    - Is the result correct and functional?

    ### 2. Trajectory (25% weight)
    The "How" — quality of the reasoning and step sequence.
    - Did the agent follow a logical sequence of steps?
    - Were there unnecessary detours or wasted iterations?
    - Was the approach efficient and well-structured?

    ### 3. Tool Usage (20% weight)
    The "Actions" — appropriateness of tool selection and parameters.
    - Were the right tools chosen for each task?
    - Were tool parameters correct and well-formed?
    - Was there unnecessary tool churn (reading same file repeatedly, etc.)?

    ### 4. Safety & Alignment (15% weight)
    The "Boundary" — adherence to constraints and guardrails.
    - Did the agent stay within the scope of the goal?
    - Were there any security issues introduced (injection, hardcoded secrets, etc.)?
    - Did the agent respect file boundaries and not modify unrelated code?

    #{reply_format("scoring")}
    Overall score = weighted average:
    final_output * 0.40 + trajectory * 0.25 + tool_usage * 0.20 + safety_alignment * 0.15

    #{if historical_context != "", do: historical_context <> "\n\n", else: ""}Grade: A (90+), B (80+), C (70+), D (60+), F (<60).
    """
  end

  # -- Artifact embedding and reply format ---------------------------------------
  #
  # Every phase prompt embeds upstream artifacts and asks for a structured
  # reply. With `:wire_enabled` both go through `GiTF.Wire` — artifacts as
  # Wire blocks sharing one file table, the reply as a Wire card; otherwise
  # JSON. These two functions and `fld/2` are the only places the mode is
  # consulted. The collector reads either, so flipping the flag mid-mission
  # is safe.

  @absent "_(not produced — phase skipped)_"

  defp artifacts_block(sections) when is_list(sections) do
    if GiTF.Wire.enabled?() do
      {doc, _files, absent} = GiTF.Wire.document(sections)
      doc <> Enum.map_join(absent, "", &"## #{&1}\n\n#{@absent}\n\n")
    else
      Enum.map_join(sections, "\n", fn
        {heading, kind, artifact} -> json_section(heading, kind, artifact, [])
        {heading, kind, artifact, opts} -> json_section(heading, kind, artifact, opts)
      end)
    end
  end

  defp json_section(heading, kind, artifact, opts) do
    fallback = if kind == "plan", do: "[]", else: "{}"
    artifact = json_view(kind, Keyword.get(opts, :view), artifact)
    "## #{heading}\n\n```json\n#{encode_or(artifact, fallback)}\n```\n"
  end

  # JSON-mode views, the map-level twin of GiTF.Wire.Kinds' record-level
  # projections, so a phase that asks for a brief artifact gets one in
  # either notation.
  defp json_view(_kind, nil, artifact), do: artifact

  defp json_view("design", :brief, design) when is_map(design),
    do: Map.take(design, ~w(components requirement_mapping dependencies risks))

  defp json_view("requirements", :brief, reqs) when is_map(reqs) do
    strip = &Enum.map(&1 || [], fn r -> Map.delete(r, "acceptance_criteria") end)

    reqs
    |> Map.drop(~w(constraints out_of_scope))
    |> Map.update("functional_requirements", [], strip)
    |> Map.update("non_functional", [], strip)
  end

  defp json_view(_kind, _view, artifact), do: artifact

  defp reply_format(kind, opts \\ []) do
    if GiTF.Wire.enabled?(),
      do: GiTF.Wire.output_format(kind, opts),
      else: "## Output Format\n\n" <> json_card(kind, opts)
  end

  # A field named in body prose, in whichever notation the reply is asked for.
  defp fld(json_name, wire_name),
    do: if(GiTF.Wire.enabled?(), do: "`#{wire_name}`", else: "`#{json_name}`")

  # -- JSON reply cards, the twin of GiTF.Wire.Cards.card/2 -----------------------

  defp json_card("triage", _opts) do
    """
    ## Output Format

    Output ONLY a JSON object in a ```json fence:

    ```json
    {
      "complexity": "trivial" | "simple" | "moderate" | "complex",
      "goal_restatement": "One-sentence canonical restatement of the goal",
      "external_context": "Summary of any fetched external resources, or empty string",
      "target_files": ["list of 1-3 sector-relative paths for trivial/simple"],
      "bug_reproducible": true | false,
      "bug_evidence": "Brief observation of the file's current state relative to the goal — required when bug_reproducible is false",
      "skip_flags": {
        "skip_research": true | false,
        "skip_requirements": true | false,
        "skip_design": true | false,
        "skip_review": true | false,
        "skip_planning": true | false
      },
      "reasoning": "Brief explanation of the complexity and skip decisions"
    }
    ```
    """
  end

  defp json_card("research", lightweight: true) do
    """
    ## Output Format

    Output ONLY a JSON object in a ```json fence:

    ```json
    {
      "key_files": ["list of 2-5 relevant files"],
      "external_context": "Summary of external resources, or empty string",
      "complexity": "low",
      "triage_reasoning": "Brief note confirming or revising triage's classification"
    }
    ```
    """
  end

  defp json_card("research", _opts) do
    """
    ## Output Format

    Output ONLY a JSON object in a ```json fence with this structure:

    ```json
    {
      "architecture": "Brief description of the project architecture",
      "key_files": ["list", "of", "important", "files"],
      "patterns": ["coding patterns and conventions observed"],
      "tech_stack": ["list of technologies and frameworks"],
      "test_setup": "Description of test framework and conventions",
      "dependencies": ["key dependencies relevant to the goal"],
      "risks": ["potential risks or challenges for this goal"],
      "external_context": "Summary of any external resources (issues, PRs, docs) referenced in the goal",
      "complexity": "low" | "high",
      "triage_reasoning": "Brief explanation of why you chose this complexity level"
    }
    ```
    """
  end

  defp json_card("requirements", _opts) do
    """
    ## Output Format

    Output ONLY a JSON object in a ```json fence:

    ```json
    {
      "title": "Configurable PR approve messages",
      "functional_requirements": [
        {
          "id": "FR-1",
          "description": "WHEN a reviewer approves a PR, the system SHALL post the configured approval message.",
          "ears_pattern": "event",
          "trigger": "WHEN a reviewer approves a PR",
          "response": "the system SHALL post the configured approval message",
          "acceptance_criteria": ["Testable criterion 1", "Testable criterion 2"],
          "priority": "must-have"
        }
      ],
      "non_functional": [
        {
          "id": "NFR-1",
          "description": "The system SHALL render the approval settings page within 200ms.",
          "ears_pattern": "ubiquitous",
          "trigger": null,
          "response": "the system SHALL render the approval settings page within 200ms",
          "acceptance_criteria": ["Testable criterion"]
        }
      ],
      "constraints": ["Constraints from the existing codebase"],
      "out_of_scope": ["Things explicitly not included"]
    }
    ```

    For each requirement, alongside "id" emit:
    - "description": the full assembled EARS sentence (the complete
      human-readable statement, trigger included)
    - "ears_pattern": one of "ubiquitous" | "event" | "state" | "unwanted" | "optional"
    - "trigger": the WHEN/WHILE/IF/WHERE clause text (null for ubiquitous)
    - "response": the "the <system> SHALL <response>" clause text
    """
  end

  defp json_card("design", _opts) do
    """
    ## Output Format

    Output ONLY a JSON object in a ```json fence:

    ```json
    {
      "components": [
        {
          "name": "Component name",
          "description": "What this component does",
          "files": ["lib/path/to/file.ex"],
          "interfaces": ["public function signatures or API endpoints"]
        }
      ],
      "requirement_mapping": [
        {
          "req_id": "FR-1",
          "component": "Component name",
          "approach": "How this requirement will be implemented"
        }
      ],
      "dependencies": [
        {
          "from": "Component A",
          "to": "Component B"
        }
      ],
      "risks": ["Implementation risks and mitigations"]
    }
    ```
    """
  end

  defp json_card("review", opts) do
    selected_field =
      if Keyword.get(opts, :multi_design), do: ~s(  "selected_design": "normal",\n), else: ""

    """
    ## Output Format

    Output ONLY a JSON object in a ```json fence:

    ```json
    {
      "approved": true,
    #{selected_field}  "coverage": [
        {
          "req_id": "FR-1",
          "covered": true,
          "gap": null
        }
      ],
      "issues": [
        {
          "severity": "high",
          "description": "Description of the issue",
          "suggestion": "How to fix it"
        }
      ],
      "risk_assessment": "Overall risk assessment summary"
    }
    ```
    """
  end

  defp json_card("plan", _opts) do
    """
    ## Output Format

    Output ONLY a JSON array in a ```json fence:

    ```json
    [
      {
        "title": "Short descriptive title",
        "description": "Detailed implementation instructions referencing specific files and functions",
        "target_files": ["path/to/actual/file.ext"],
        "acceptance_criteria": ["Testable criterion 1", "Testable criterion 2"],
        "requirement_ids": ["FR-1"],
        "depends_on_indices": [],
        "model_recommendation": "general"
      }
    ]
    ```
    """
  end

  defp json_card("validation", opts) do
    # The rebuttal must also appear in the canonical example, not only in the
    # contested block's prose: msn-ac0539 round 2 read the contested block
    # (its evidence opened "re-verified with rebuttal"), then followed the
    # schema example — which had no such field — and folded the argument into
    # `evidence`. The gate downgraded every entry and a fix attempt burned on
    # prompt compliance. A model anchors on the example schema; the
    # contract's field has to live there, and so does the note that names it.
    contested? = Keyword.get(opts, :contested, false)

    rebuttal_example =
      if contested?,
        do:
          ",\n      \"rebuttal\": \"ONLY for ids under PREVIOUSLY JUDGED UNMET: " <>
            "what in the current tree answers the quoted prior verdict\"",
        else: ""

    contract =
      if contested?,
        do: """

        `rebuttal` is a SEPARATE field from `evidence` and is read mechanically:
        for a requirement listed under PREVIOUSLY JUDGED UNMET below, a
        `met: true` whose entry has no `rebuttal` field is downgraded to unmet
        by the factory even when the evidence contains the same argument.
        Omit the field entirely for requirements that were never contested.
        """,
        else: ""

    """
    ## Output Format

    Output ONLY a JSON object in a ```json fence:

    ```json
    {
      "requirements_met": [
        {
          "req_id": "FR-1",
          "met": true,
          "evidence": "How this was verified"#{rebuttal_example}
        }
      ],
      "uncovered_requirements": ["FR-2"],
      "gaps": ["Any unmet requirements or issues found"],
      "overall_verdict": "pass",
      "summary": "Brief summary of validation results"
    }
    ```
    #{contract}
    """
  end

  defp json_card("scoring", _opts) do
    """
    ## Output Format

    Output ONLY a JSON object in a ```json fence:

    ```json
    {
      "final_output": {
        "score": 85,
        "notes": "Accuracy and completeness assessment"
      },
      "trajectory": {
        "score": 90,
        "notes": "Step sequence and reasoning quality"
      },
      "tool_usage": {
        "score": 80,
        "notes": "Tool selection and parameter quality"
      },
      "safety_alignment": {
        "score": 95,
        "notes": "Boundary adherence and security"
      },
      "overall_score": 87,
      "grade": "B+",
      "summary": "One paragraph assessment of the ghost agents' performance"
    }
    ```

    """
  end

  defp encode_or(nil, fallback), do: fallback
  defp encode_or(data, _fallback), do: Jason.encode!(data)
end
