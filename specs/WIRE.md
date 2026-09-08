# Wire — the GiTF compact artifact notation

**Status:** built, tested, default-off (`GITF_WIRE_ENABLED` / `[features] wire_enabled`).
**Version:** 1. **Code:** `lib/gitf/wire.ex` and `lib/gitf/wire/*.ex`.
**Reference decoder (outside the factory):** `specs/wire/wire.py` (stdlib only), checked
against `specs/wire/vectors/` by `test/gitf/wire_test.exs`.

Wire is what a phase ghost reads and writes instead of JSON. Every artifact the Major
pipeline hands between phases — triage, research, requirements, design, review, plan,
validation, scoring — is a JSON-shaped map internally and stays one. Wire is a **codec**
on the model boundary: prompts embed prior artifacts as Wire and ask for Wire replies; the
collector decodes a Wire reply into exactly the map a JSON reply would have produced.
Nothing downstream of the collector knows Wire exists, and the collector still accepts
JSON, so a model that ignores the card still lands.

---

## 1. The question this answers, and the honest answer

> What compact DSL minimises total input/output tokens while preserving enough
> information that Sonnet/Haiku complete the task at the same success rate?

The measurement (§7) says the notation is the **smaller** half of the answer. Real phase
artifacts are prose: in the requirements artifact of msn-ac0539, pure JSON punctuation is
7% of the tokens. A notation can only remove scaffolding, key repetition and duplicated
values. What actually moves total tokens is *what* gets sent and *how many times*:

| Lever | Mechanism | Where |
|---|---|---|
| Remove scaffolding | one record per line, tag once, no quotes/braces/keys | §2 grammar |
| Reference, don't repeat | paths, requirement ids, component names declared once, cited by id | §2.4 |
| Derive, don't duplicate | EARS `trigger`/`response` derived from the sentence | §3.3 |
| Send the projection a phase needs | *views*: `requirements@brief` to scoring, `design@brief` to multi-design review — in both notations | §5 |
| Budget prose nobody consumes | `≤N words` on fields only the operator reads | §6 |
| Stop leaking transcripts | a parse-failed validator's `raw_output` (50KB) was persisted into the fix history and rendered into every later fix prompt | §7.3 |

Success rate is preserved by construction, not by compression: **prose fields keep their
full natural-language content** (acceptance criteria, evidence, op briefs, risks); only
punctuation, keys and duplicates are removed. Word budgets apply solely to fields no later
phase reads mechanically. The decoder is lenient (§2.5) and JSON remains accepted, so the
failure mode "model wrote it slightly wrong" degrades to "parsed leniently", not to a lost
phase. The empirical check is the A/B protocol in §8.

---

## 2. Grammar (normative)

A Wire document is UTF-8 text, one record per line.

```
document    = [header NL] { line NL } ;
header      = "%wire" SP version [SP kind] ;            (* "%wire 1 plan" *)
line        = record | property | continuation | comment | blank ;
record      = tag [id] [SP head] [SP "|" SP text] ;      (* column 0 *)
property    = "  " tag [id] [SP head] [SP "|" SP text] ; (* 1–3 spaces; belongs to the record above *)
continuation= "    " text ;                              (* 4+ spaces; appends to the previous text *)
comment     = "#" { any } ;                              (* column 0 only *)
tag         = letter { letter | "_" } ;                  (* case-sensitive: "R", "ac", "cov" *)
id          = digit { digit } ;                          (* "R12" → tag R, id 12 *)
head        = atom { SP atom } ;                         (* space-separated, no spaces inside *)
atom        = enum | ref | reflist | "y" | "n" | integer | "-" ;
text        = { any } ;                                  (* to end of line — may contain " | " *)
```

### 2.1 The one rule that removes all escaping

A line has at most **one** free-text field and it is always **last**, after the first
` | ` (space, bar, space). The head is a run of space-separated atoms that can never
contain spaces. Consequently the text may contain anything at all — including ` | `, code,
quotes, braces — and there is no escape syntax. The design artifact line

```
M R1 C1 | Append | "author" to the GroupMode union at line 78. TypeScript then …
```

decodes to head `["R1","C1"]` and text `Append | "author" to the GroupMode union …`.

### 2.2 Head arity is declared per tag, per kind

Whether a tag has a head, and how many atoms, is fixed by the kind's table (§3). A tag
whose arity is 0 — or any tag not in the table — takes **everything** after it as text
with no bar: `goal Add an author grouping mode`, `ac GroupMode is "org" | "repo"`.
For a tag with arity *k*, the head is everything before the first ` | `. Lenient form:
if the line has no ` | `, the first *k* whitespace-separated tokens are the head and any
remainder is text (`cx simple`, `cov R1 y`).

### 2.3 Properties and continuations

A property is a record indented 1–3 spaces (a leading tab counts as two spaces); it
attaches to the nearest preceding column-0 record and uses the same `tag head | text`
shape. A line indented 4+ spaces continues the text of the previous record or property,
joined with a newline; a blank line between two continuation lines is preserved as a
paragraph break (`\n\n`). Blank lines elsewhere are ignored.

### 2.4 Identifiers

| Form | Meaning | JSON equivalent |
|---|---|---|
| `R<n>` | functional requirement | `"FR-<n>"` |
| `N<n>` | non-functional requirement | `"NFR-<n>"` |
| `F<n>` | file, declared by `F<n> path` | the path |
| `C<n>` | design component, declared by `C<n> … \| name` | the component's `name` |
| `O<n>` | planned op (1-based) | index `n-1` in `depends_on_indices` |
| `-` | none / null / empty list | `null` or `[]` per field |
| `a,b,c` | id list — commas, no spaces (`F1,F3`, `R1,R2,N1`) | array |

**File table.** `F<n> path` declares a file once. A document that embeds several
artifacts (a prompt) carries one table, rendered first under `## Files` in a fence headed
`%wire 1 files`; every block cites it. That header is how a decoder finds the table again
in a stored prompt — the output card's example `F` lines live in another fence and must
never shadow it. A reply may cite the table of the prompt it answers and may extend it with new
declarations, numbered after the highest `F` it was shown. **A bare path is accepted
anywhere an `F` ref is** (`f F2,src/new.ts`). Decoders resolve refs against the union of
the context table and the document's own declarations; the document's declaration wins
on conflict; an unknown `F` id resolves to nothing rather than failing.

### 2.5 Decoder tolerance (normative for conformance)

A conforming decoder MUST:

- find the Wire body as the **last** ```` ```wire ```` fence in the text, or the whole text
  if it begins with `%wire`; treat the header as optional;
- ignore comment lines and lines it cannot classify (never fail the document);
- accept a trailing colon on a tag (`verdict: pass`), CRLF, and tab indentation;
- accept enum values in either the Wire short form or the JSON long form,
  case-insensitively (`med`/`medium`, `ubiq`/`ubiquitous`);
- accept booleans `y|n|yes|no|true|false|1|0|met|unmet`;
- accept requirement refs as `R1` or `FR-1`, op refs as `O2` or `2`;
- take the **last** occurrence of a singleton record (`verdict`, `cx`, `ok`);
- default a missing enum to the value the kind's table names; default a missing
  boolean as the table says; default missing text to `""` and missing lists to `[]`.

The only hard failures are "no Wire in the text" and "a Wire body with zero records".

---

## 3. Kinds (normative tables)

Each table lists the records of a kind, their head atoms in order, what the text is, and
the JSON key(s) they produce. *rep* = the line repeats, one per item. Records may appear in
any order; the tables show the conventional one (the one cards teach and the encoder
emits).

### 3.1 `triage`

| Record | Head | Text | JSON |
|---|---|---|---|
| `cx` | `trivial\|simple\|moderate\|complex` | — | `complexity` |
| `goal` | — | restatement | `goal_restatement` |
| `ext` | — | external context (omit if none) | `external_context` (`""` when absent) |
| `F<n>` *rep* | — | path | `target_files` (in id order) |
| `bug` | `y\|n` | evidence sentence | `bug_reproducible` (default `true`), `bug_evidence` |
| `skip` | comma list of `research,requirements,design,review,planning`, or `-` | — | `skip_flags.skip_<phase>` — `true` iff listed |
| `why` | — | reasoning | `reasoning` |
| `files` | id list | — | *embedding form only:* `target_files` when present, else the `F` declarations |

### 3.2 `research`

| Record | Head | Text | JSON |
|---|---|---|---|
| `arch` | — | text | `architecture` |
| `F<n>` *rep* | — | path | `key_files` |
| `pat` *rep* | — | text | `patterns[]` |
| `tech` *rep* | — | text | `tech_stack[]` |
| `test` | — | text | `test_setup` |
| `dep` *rep* | — | text | `dependencies[]` |
| `risk` *rep* | — | text | `risks[]` |
| `ext` | — | text | `external_context` |
| `cx` | `low\|high` | — | `complexity` (default `low`) |
| `why` | — | text | `triage_reasoning` |
| `files` | id list | — | embedding form of `key_files` (as in triage) |

The six comprehensive keys (`architecture … risks`) are emitted iff any of
`arch pat tech test dep risk` is present; a lightweight artifact has only the last four.

### 3.3 `requirements`

| Record | Head | Text | JSON |
|---|---|---|---|
| `title` | — | text | `title` |
| `R<n>` *rep* | `<ubiq\|event\|state\|unwanted\|opt> <must\|should\|could>` | complete EARS sentence | `functional_requirements[]`: `id "FR-<n>"`, `ears_pattern`, `priority` (`must-have\|should-have\|nice-to-have`), `description`, derived `trigger`/`response` |
| ↳ `ac` *rep* | — | criterion | `acceptance_criteria[]` |
| `N<n>` *rep* | `<pattern>` | complete EARS sentence | `non_functional[]`: `id "NFR-<n>"`, `ears_pattern`, `description`, derived `trigger`/`response` |
| ↳ `ac` *rep* | — | criterion | `acceptance_criteria[]` |
| `con` *rep* | — | text | `constraints[]` |
| `out` *rep* | — | text | `out_of_scope[]` |

**Derivation of `trigger`/`response`.** Match the description against
`^\s*((?:WHEN|WHILE|IF|WHERE)\b.*?),\s*(?:THEN\s+)?((?:\S+\s+){1,4}SHALL\b.*)$`
(case-insensitive, lazy): group 1 is `trigger`, group 2 with a trailing `.` removed is
`response`. No match → `trigger` is `null`, `response` is the description without its
trailing `.`. The lazy match makes `IF a repo, author, or PR is at …, THEN the system
SHALL …` split at the clause boundary, not the first comma. These two fields were
"strictly additive" in the JSON schema — no consumer reads them — so a literal derivation
is preferred to asking the model to write the sentence three times.

### 3.4 `design`

| Record | Head | Text | JSON |
|---|---|---|---|
| `F<n>` *rep* | — | path | file table |
| `C<n>` *rep* | file id list (or `-`) | component name | `components[]`: `name`, `files` |
| ↳ `desc` | — | text | `description` |
| ↳ `if` *rep* | — | text | `interfaces[]` |
| `M` *rep* | `<R\|N ref> <C ref>` | approach | `requirement_mapping[]`: `req_id`, `component` (the C's **name**), `approach` |
| `D` *rep* | `<C ref> <C ref>` | — | `dependencies[]`: `from`, `to` (names) |
| `K` *rep* | — | text | `risks[]` |

### 3.5 `review`

| Record | Head | Text | JSON |
|---|---|---|---|
| `ok` | `y\|n` | — | `approved` (default `false`) |
| `sel` | `minimal\|normal\|complex` | — | `selected_design` (only when present) |
| `cov` *rep* | `<R\|N ref> <y\|n>` | gap (only when `n`) | `coverage[]`: `req_id`, `covered` (default `true`), `gap` (`null` when no text) |
| `I<n>` *rep* | `high\|med\|low` | description | `issues[]`: `severity` (`high\|medium\|low`), `description` |
| ↳ `fix` | — | text | `suggestion` |
| `risk` | — | text | `risk_assessment` |

### 3.6 `plan` (alias `planning`) — the artifact is a JSON **array**

| Record | Head | Text | JSON |
|---|---|---|---|
| `F<n>` *rep* | — | path | file table |
| `O<n>` *rep* | `general\|thinking\|fast` | title | one op: `model_recommendation`, `title` |
| ↳ `f` | file id list | — | `target_files` |
| ↳ `r` | requirement id list | — | `requirement_ids` |
| ↳ `dep` | op id list (omit when none) | — | `depends_on_indices` (0-based) |
| ↳ `ac` *rep* | — | criterion | `acceptance_criteria[]` |
| ↳ `do` | — | brief, multi-line via continuation | `description` |

Ops are emitted in document order; `O<n>` numbering is expected to be 1..k in order and
`dep O2` means index 1.

### 3.7 `validation`

| Record | Head | Text | JSON |
|---|---|---|---|
| `V` *rep* | `<R\|N ref> <y\|n>` | evidence | `requirements_met[]`: `req_id`, `met` (default `false`), `evidence` |
| ↳ `rebut` | — | text | `rebuttal` (key present only when the line is) |
| `unc` | requirement id list or `-` | — | `uncovered_requirements` |
| `gap` *rep* | — | text | `gaps[]` |
| `verdict` | `pass\|fail` | — | `overall_verdict` (default `fail`) |
| `sum` | — | text | `summary` |

`rebut` is the Wire form of the contested-requirement contract enforced by
`GiTF.Phases.Validation.enforce_contested_rebuttals/1`: a `V R<n> y` for a contested id
without a `rebut` line is downgraded to unmet. The card shows the line only when the
prompt carries a contested block.

### 3.8 `scoring`

| Record | Head | Text | JSON |
|---|---|---|---|
| `out` | integer 0–100 | notes | `final_output.{score,notes}` |
| `traj` | integer | notes | `trajectory.{score,notes}` |
| `tool` | integer | notes | `tool_usage.{score,notes}` |
| `safe` | integer | notes | `safety_alignment.{score,notes}` |
| `overall` | `<integer> <grade>` | — | `overall_score`, `grade` |
| `sum` | — | text | `summary` |

---

## 4. Documents: how a prompt and a reply are shaped

A **prompt** built with the flag on contains, in this order:

```
## Files

```wire
%wire 1 files
F1 src/windows/MainApp.tsx
F2 src/windows/MainApp.css
```

## Requirements

```wire
%wire 1 requirements
title …
R1 ubiq must | …
  ac …
```

## Technical Design

```wire
%wire 1 design
C1 F1 | GroupMode type & group-by select
  desc …
M R1 C1 | …
```

## Output Format

Output ONLY a Wire document in a ```wire fence — no JSON, no prose outside the fence.

<grammar card, ~150 tokens, identical in every prompt>
<kind card — the record table as an example, annotations as # comments>
```

The file table comes first so every `F<n>` a block cites has been seen. Blocks never
re-declare files. An artifact a skipped phase never produced is rendered as
`_(not produced — phase skipped)_` under its heading rather than as `{}`.

A **reply** is one fenced Wire document: header, any new `F` declarations, records. The
collector recovers the prompt's file table from the stored prompt (`GiTF.Wire.files_in/1`
reads the `%wire 1 files` fence — the prompt *is* the phase op's `description`, so this is
stateless) and decodes the reply against it.

Kind cards are deliberately example-shaped: models anchor on the example schema, not on
prose above it (msn-ac0539 round 2). Every field the decoder reads is visible in the card;
annotations are `#` comment lines because a trailing parenthetical on a text line would be
copied into the value.

---

## 5. Views

A view is a projection of an artifact for a phase that needs its skeleton, not its bulk.
Views are an **encoder** concern; the decoder is unchanged. A view is a property of the
prompt section, honoured in both notations — record-level in Wire (`GiTF.Wire.Kinds`),
map-level in JSON (`GiTF.Major.PhasePrompts.json_view/3`) — so the saving does not depend
on the flag.

| View | Keeps | Drops | Used by |
|---|---|---|---|
| `requirements@brief` | `title`, every `R`/`N` line | `ac`, `con`, `out` | scoring (judges from the validation result; needs the requirement text only) |
| `design@brief` | `F`, `C`, `M`, `D`, `K` | `desc`, `if` | multi-design review |

Design, review, planning and validation still receive the **full** requirements: coverage
and feasibility judgements read acceptance criteria, and shaving them is exactly the kind
of information loss that would move success rate.

---

## 6. Word budgets

The cards mark fields with `≤N words` **only** where no later phase reads the field
mechanically — it exists for the operator and the dashboard:

| Field | Budget | Why it is safe |
|---|---|---|
| triage `why`, research `why` | 40 | logged; not consumed |
| research `arch` | 60 | context for later phases, not acted on line by line |
| design `desc` / `M` approach / `K` | 40 / 60 / 40 | planning reads them as context; briefs carry the detail |
| review `risk` | 60 | **not passed to planning at all** (only `issues` and `sel` are) |
| validation `V` evidence / `sum` | 50 / 60 | fix ghosts act on `gap` and unmet `V` lines; file:line beats paragraphs |
| scoring notes / `sum` | 40 / 80 | dashboard only |

Requirement sentences, acceptance criteria, `gap` lines, `fix` lines and op `do` briefs
carry **no** budget. Budgets are advisory to the model; the decoder never truncates.

---

## 7. Measurement

Tokenizer: `cl100k_base` via tiktoken, as a proxy (Claude's tokenizer differs; ratios,
not absolutes, are the claim). Corpus: the real artifacts of msn-ac0539 (six-level
priority, 13 FR + 3 NFR) and msn-aa7470 (author group-by), fetched from the running
factory and stored as `test/support/fixtures/wire/*.json`. Script: the counts below are
reproducible from `test/support/fixtures/wire` with `GiTF.Wire.encode/2` and tiktoken.

### 7.1 Artifacts — what a phase reads (compact JSON) and what a model writes (pretty JSON)

| kind | JSON compact | JSON pretty | Wire | vs compact | vs pretty |
|---|---:|---:|---:|---:|---:|
| triage | 316 | 356 | 283 | 10% | 21% |
| research (lightweight) | 173 | 189 | 172 | 1% | 9% |
| requirements | 2951 | 3510 | 2341 | **21%** | **33%** |
| design | 1898 | 2142 | 1696 | 11% | 21% |
| review | 815 | 954 | 702 | 14% | 26% |
| plan | 1364 | 1476 | 1334 | 2% | 10% |
| validation | 1623 | 1851 | 1446 | 11% | 22% |
| scoring | 796 | 850 | 777 | 2% | 9% |
| **total** | 9936 | 11328 | 8751 | **12%** | **23%** |

Models emit pretty JSON, so **23% is the structural output saving** before word budgets.
Requirements gains most because `description` duplicated `trigger`+`response`; plan and
scoring gain least because they are almost entirely prose (the op brief, the notes).

### 7.2 Full prompts — the eight phase prompts built from the same artifacts

Three columns: the prompts as they were before this work; JSON mode now (the flag off —
the brief views apply in both notations); Wire mode (the flag on).

| phase | before | JSON mode now | Wire mode | Wire vs before |
|---|---:|---:|---:|---:|
| triage | 1103 | 1101 | 1232 | −12% |
| research | 368 | 372 | 512 | −39% |
| requirements | 893 | 897 | 919 | −3% |
| design | 3389 | 3393 | 2967 | 12% |
| review | 5369 | 5375 | 4744 | 12% |
| planning | 5774 | 5775 | 5220 | 10% |
| validation | 4756 | 4760 | 4355 | 8% |
| scoring | 5101 | 3500 | 2774 | **46%** |
| **total** | 26753 | 25173 | 22723 | **15%** |

Of the 15%, the brief view alone is 6 points and is on today, flag or no flag; the
notation is the other 9. The three small phases lose ~100–150 tokens each: the grammar
card is a fixed cost and those prompts embed nothing. They still win on the reply side
(triage: 73 fewer output tokens ≈ 365 input-token equivalents at 5×). Placing the grammar
card in a cached system prompt would remove the fixed cost entirely; that is the next
step (§9).

### 7.3 The leak that outweighs all of the above

msn-ac0539's third fix prompt was **77,283 bytes (~20K tokens)** — 51KB of it one prior
attempt's `raw_output` (the validator's raw stream-json transcript, stored because its
reply failed to parse) rendered as a markdown bullet, plus every `requirements_met` entry
of every prior attempt, twelve of which read "accepted in an earlier validation round".
That single prompt cost more than every phase artifact of the mission combined.
The leak was created where the attempt was recorded: `Validation.do_attempt_fixes` copied
the whole validation artifact into the `FixContext` history, which is persisted on the
mission and on every later fix op. Fixed unconditionally at that point —
`FixContext.digest/1` keeps only the unmet entries, uncovered ids, gaps, verdict and
summary (an allowlist, so future artifact keys cannot leak), applied at record time and
again at render time for histories persisted before it existed. The same change stopped
the current validation being rendered twice (once as feedback, once as "Attempt N"), and
the parse-failed fallback summary now comes from the assistant's reply, not the transcript.
The fix history stays markdown in both modes: a fix ghost is an implementation session that
never receives the grammar card, so Wire there would be a legend-less notation.

### 7.4 Cost model

Per full-pipeline mission at Sonnet list prices ($3/M in, $15/M out): phase prompts
≈26.8K→22.7K input and ≈11.3K→8.8K output (structural only) → **$0.25 → $0.20 (−20%)**
before word budgets and before the fix-loop leak. Over the 30-day window in
`costs_summary` the planning+verification categories were $137 of $385, so the notation
alone is worth on the order of $25–30/month at current volume; the fix-history leak,
when it fires, is worth more per incident than the notation is per mission.

---

## 8. Success-rate protocol (the claim the measurement cannot make)

Equal success rate is an empirical claim about models, not a property of a grammar. The
argument for expecting it: no prose is removed or shortened where a later phase acts on
it; the card is example-shaped and complete; the decoder is lenient and accepts JSON. The
test:

1. Keep `wire_enabled` off. Note the current baseline: msn-5f2be2 (fast), msn-ac0539
   (full) are the recent acceptance runs.
2. Turn it on for the box (`[features] wire_enabled = true`, reload — no restart).
3. Re-run the **same** missions unchanged, per the failure doctrine. Compare: phase
   parse-failure count (must stay 0 — `journalctl -u gitf | grep "structured-output
   extraction failed"`), validation verdicts, fix-loop rounds, wall clock, `costs_summary`
   by category.
4. Any phase whose reply the collector had to fall back to JSON for, or that parsed with
   skipped lines, is a card defect: fix the card, not the mission.

If a fast-tier model (Haiku) shows a higher parse-fallback rate than Sonnet, the
mitigation is per-tier: keep the JSON card for that tier (the flag can become tiered),
not to weaken the grammar.

---

## 9. Operating notes and next steps

- **Flag:** `GITF_WIRE_ENABLED=1` at boot or `[features] wire_enabled = true` (reload).
  Prompt side only — decoding is always on, so flipping mid-mission is safe: a running
  phase that was asked for JSON still parses; the next phase is asked for Wire.
- **Regenerate vectors** when the encoder changes:
  `mix run` the snippet in `test/gitf/wire_test.exs` ("the vectors are the fixtures
  round-tripped") fails until `specs/wire/vectors/` is regenerated from the fixtures.
- **Adding a kind:** a `heads/1` clause, `decode/3` and `encode_full/3` clauses in
  `GiTF.Wire.Kinds`, a card in `GiTF.Wire.Cards`, the table here, the Python decoder,
  a fixture and a vector. The card test enforces that every tag appears in the card.
- **Next:** move the grammar card into the phase ghost's system prompt (cached across
  phases — the Anthropic cache keys on the identical prefix) and it stops costing
  anything; Wire-encode the op brief written to `.claude/instructions.md`; a tiered flag
  if §8 shows a fast-tier gap.

---

## 10. Worked example

The plan reply for msn-aa7470, as a model would write it against a prompt that declared
`F1 src/windows/MainApp.tsx`:

```wire
%wire 1 plan
F2 src/windows/MainApp.css
O1 thinking | Add author group-by mode to PR rail
  f F1
  r R1,R2,R3,R4,R5,R6,R7,R8,R9,N1
  ac GroupMode is typed as "org" | "repo" | "reason" | "type" | "author" and TypeScript compiles with no new errors
  ac The group-by <select> contains <option value="author">Author</option> in addition to the unchanged existing four options
  do In src/windows/MainApp.tsx, add an "author" grouping mode to the PR rail alongside the existing org/repo/reason/type modes.

    1. GroupMode type (line ~78): change `type GroupMode = "org" | "repo" | "reason" | "type";` to include `| "author"`.

    2. Group-by <select> (~lines 2019-2024): add `<option value="author">Author</option>` after the existing four.
O2 general | Style the author group badge
  f F2,F1
  r R7
  dep O1
  ac A `.prio-tag.author` rule exists and the badge renders with the same metrics as the repo badge
  do Add the author badge styling in src/windows/MainApp.css next to the existing `.prio-tag` rules.
```

decodes (`python3 specs/wire/wire.py plan --files prompt.md reply.wire`) to the two-element
`planning` array with `target_files: ["src/windows/MainApp.tsx"]`,
`requirement_ids: ["FR-1", …, "NFR-1"]`, `depends_on_indices: [0]` on the second op, and
the multi-paragraph `description` intact. Note the ` | ` inside the first `ac` line: it is
text, and no escaping was needed.
