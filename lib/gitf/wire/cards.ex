defmodule GiTF.Wire.Cards do
  @moduledoc """
  The model-facing text of Wire: the grammar card that goes into every
  prompt that expects a Wire reply, and one output card per artifact kind.

  Cards are the contract the model anchors on, so every field the decoder
  reads must be visible here (msn-ac0539 round 2: a field described in
  prose but missing from the example schema was folded into another
  field, and the gate downgraded every entry). `test/gitf/wire_test.exs`
  checks each kind's card against its record vocabulary.

  Annotations inside a card are `#` comment lines, never trailing text —
  a record's free text runs to end of line, so a copied parenthetical
  would become part of the value.

  Word budgets (`≤N words`) mark fields that no later phase reads
  mechanically — they exist for the operator and the dashboard — so
  brevity there costs nothing downstream and saves output tokens, the
  expensive direction. Fields another phase acts on (requirement text,
  acceptance criteria, op briefs) carry no budget.

  The grammar card is ~150 tokens and identical in every prompt; keep it
  that way — it is the fixed cost the notation has to earn back. Backticks
  and angle brackets are expensive there: "Fn path" is three tokens,
  "`F<n> path`" is eight.
  """

  @grammar """
  Wire: one record per line. Column 0: TAGn head | text. Two-space indent: a property
  of the record above, same shape. Four-space indent: continues the previous text.
  Head = short atoms (enum, id, y/n, number). Text = everything after the first " | ",
  any characters. A tag without a head takes all text, no bar. Lists: repeat the line.
  Id lists: F1,F3 (no spaces). None: -. Comments: #.
  Ids: Rn=FR-n Nn=NFR-n Fn=file Cn=component On=op. Declare each file once (Fn path,
  numbered after the highest F shown to you) then cite it; a bare path also works.
  """

  @doc "The grammar card. Include once, before the kind's output card."
  @spec grammar() :: String.t()
  def grammar, do: @grammar

  @doc """
  The output card for `kind`. `opts`:

    * `:contested` — validation only: show the `rebut` property
    * `:multi_design` — review only: show the `sel` record
  """
  @spec card(String.t(), keyword()) :: String.t()
  def card(kind, opts \\ [])

  def card("triage", _opts) do
    """
    ```wire
    %wire 1 triage
    cx trivial|simple|moderate|complex
    goal One-sentence canonical restatement of the goal
    # ext: omit when nothing was fetched
    ext Summary of fetched external resources
    # F lines are the target files, sector-relative — REQUIRED (1-3) for trivial/simple
    F1 src/path/to/file.ext
    # bug: y|n then ONE sentence stating what you literally saw in the file (required)
    bug y | MainApp.tsx:78 declares the union with no author branch — the reported state IS present.
    # skip: comma list from research,requirements,design,review,planning; `-` for none
    skip research,requirements,design
    # why: ≤40 words
    why Why this complexity and these skips
    ```
    """
  end

  def card("research", _opts) do
    """
    ```wire
    %wire 1 research
    # arch/pat/tech/test/dep/risk: comprehensive research only; one line per item; arch ≤60 words
    arch Brief description of the project architecture
    # F lines are the key files, one per line
    F1 src/path/to/file.ext
    pat A coding pattern or convention observed
    tech A technology or framework
    test Test framework and conventions
    dep A key dependency relevant to the goal
    risk A risk or challenge for this goal
    # ext: omit when nothing was fetched
    ext Summary of external resources
    cx low|high
    # why: ≤40 words
    why Why you chose this complexity
    ```
    """
  end

  def card("requirements", _opts) do
    """
    ```wire
    %wire 1 requirements
    title 3-5 word PR-style name of the work
    # R<n> = functional (FR-n). Head: <ubiq|event|state|unwanted|opt> <must|should|could>
    # text = the complete EARS sentence, trigger included, exactly one SHALL
    R1 event must | WHEN a reviewer approves a PR, the system SHALL post the configured approval message.
      ac Testable criterion
      ac Another testable criterion
    R2 ubiq must | The system SHALL log every authentication attempt.
      ac Testable criterion
    # N<n> = non-functional (NFR-n). Head: the pattern only
    N1 ubiq | The system SHALL render the approval settings page within 200ms.
      ac Testable criterion
    con A constraint from the existing codebase
    out Something explicitly not included
    ```
    """
  end

  def card("design", _opts) do
    """
    ```wire
    %wire 1 design
    # declare each file once, then cite it
    F1 lib/path/to/file.ex
    F2 lib/path/to/other.ex
    # C<n>: head = files it touches; text = component name; desc ≤40 words
    C1 F1,F2 | Component name
      desc What this component does
      if Public function signature or API endpoint
    # M: one per requirement — which component delivers it and how (planning builds from this: be concrete)
    M R1 C1 | How this requirement is implemented by that component
    # D: C1 depends on C2
    D C1 C2
    # K: a risk and its mitigation, ≤40 words each
    K An implementation risk and its mitigation
    ```
    """
  end

  def card("review", opts) do
    sel =
      if Keyword.get(opts, :multi_design),
        do: "# sel: the design you selected\nsel minimal|normal|complex\n",
        else: ""

    """
    ```wire
    %wire 1 review
    # ok: n if any high-severity issue or uncovered requirement
    ok y
    #{sel}# cov: one line per requirement; add ` | what is missing` when n
    cov R1 y
    cov R2 n | No component reads the new setting
    # I<n>: an issue the planner must act on; fix = how
    I1 high | Description of the issue
      fix How to fix it
    # risk: ≤60 words — nothing downstream reads this, the operator does
    risk Overall risk assessment
    ```
    """
  end

  def card("plan", _opts) do
    """
    ```wire
    %wire 1 plan
    # declare each target file once — real files in the project
    F1 src/path/to/file.ext
    F2 src/path/to/other.ext
    # O<n>: head = general|thinking; text = short title. r = requirement ids THIS op delivers
    # (every R must appear in some op); dep = ops this op needs first, omit when none
    O1 general | Short descriptive title
      f F1,F2
      r R1,R3
      ac Testable criterion
      ac Another testable criterion
      do Complete, ordered implementation brief naming files and functions.
        Continue on 4-space-indented lines; blank lines between paragraphs are fine.
    O2 thinking | Second op
      f F2
      r R2
      dep O1
      ac Testable criterion
      do Brief for the second op.
    ```
    """
  end

  def card("validation", opts) do
    rebut =
      if Keyword.get(opts, :contested),
        do:
          "# rebut: ONLY for ids under PREVIOUSLY JUDGED UNMET — what in the current tree answers the quoted prior verdict\n" <>
            "  rebut Commit 44036ab replaces the exact code the prior round quoted; see file:line\n",
        else: ""

    # The contract note travels with the card that names the field: the
    # factory reads `rebut` mechanically (Phases.Validation.enforce_contested_rebuttals/1).
    contract =
      if Keyword.get(opts, :contested),
        do: """

        `rebut` is a SEPARATE property line under the `V` record, not part of
        its evidence text, and is read mechanically: for a requirement listed
        under PREVIOUSLY JUDGED UNMET, a `V R<n> y` with no `rebut` line is
        downgraded to unmet by the factory even when the evidence contains the
        same argument. Omit the line entirely for requirements that were never
        contested.
        """,
        else: ""

    """
    ```wire
    %wire 1 validation
    # V: one per requirement — y|n, then evidence: file:line, command run, what you observed (a fix ghost works from this: be complete)
    V R1 y | src/x.ts:78 declares the union; `npm run typecheck` exits 0
    #{rebut}V R2 n | What is missing and where you looked
    # unc: ids no op claimed AND no evidence delivered; `unc -` when none
    unc R4,N2
    # gap: one per unmet requirement or defect, precise enough for a fix ghost to act on
    gap An unmet requirement or issue found
    # verdict: fail if any must-have requirement is unmet
    verdict pass
    # sum: ≤60 words
    sum Brief summary of validation results
    ```
    #{contract}
    """
  end

  def card("scoring", _opts) do
    """
    ```wire
    %wire 1 scoring
    # notes ≤40 words each; sum ≤80 words — read by the operator only
    out 85 | Accuracy and completeness assessment
    traj 90 | Step sequence and reasoning quality
    tool 80 | Tool selection and parameter quality
    safe 95 | Boundary adherence and security
    overall 87 B+
    sum Assessment of the ghost agents' performance
    ```
    """
  end

  @doc """
  The full output-format section for a prompt: the instruction line, the
  grammar card and the kind's card.
  """
  @spec output_format(String.t(), keyword()) :: String.t()
  def output_format(kind, opts \\ []) do
    """
    ## Output Format

    Output ONLY a Wire document in a ```wire fence — no JSON, no prose outside the fence.

    #{grammar()}
    #{card(kind, opts)}
    """
  end
end
