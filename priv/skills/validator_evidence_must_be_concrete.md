---
name: validator-evidence-must-be-concrete
description: When the triage or validator phase produces evidence (for bug reports, requirements coverage, or gaps), the evidence must point at concrete code locations — `file.ext:line` or `file.ext:function` references — not prose like "I think line 1664 might be the issue." Prose evidence is unactionable and downstream phases cannot match it to real changes.
---

# Validator evidence must be concrete

Any claim about "this is the bug" or "this requirement is met" needs a file-and-line citation. Prose alone is not evidence.

## Strong evidence (accepted)

- `app/src/components/DiffViewer.tsx:142` — the label literal
- `lib/gitf/ops.ex:create/2` — where status is set
- `test/mission_test.exs:58-71` — the failing assertion

## Weak evidence (rejected)

- "I saw something on line 142."
- "The problem is probably in the diff viewer."
- "There's a bug somewhere around the create function."

## Why concrete evidence matters

- Downstream phases (implementation, validation) cannot verify vague references. They will hallucinate a plausible fix that matches the prose rather than the actual bug.
- The cross-check step (validator pass + no real commits in non-`.claude/` files → override to fail) only fires against actual changed files. If evidence is prose, the cross-check has no signal to compare against.
- Operators reviewing a failed mission need to click through to the exact location; prose makes this manual and slow.

## When producing evidence

- Open the file, find the exact line, cite it with `path/to/file.ext:N` format (colon + line number).
- For multi-line spans, use `path:N-M`.
- For functions/methods, `path:function_name/arity` is acceptable if the line may change.
- Never paraphrase location — "the label on the welcome page" is not a citation.

## When reviewing evidence

- If every gap/requirement_met entry lacks a `file:line` reference, the validator output is probably fabricated. Downgrade verdict to fail.
- One bad citation doesn't invalidate the whole report, but a pattern of prose-only evidence is a red flag.
