---
name: commit-meaningful-changes-only
description: When completing an implementation op, the commits must include changes to actual source files — not just `.claude/` settings, agent profiles, or scratch files. A validator that says "pass" against a mission whose only commits are `.claude/instructions.md` or similar is hallucinating; the cross-check will override to fail.
---

# Commit meaningful changes only

An op's "done" state is defined by what ends up in git, not by what the agent says it did. If the only files touched are settings/scratch/metadata, the mission has produced nothing shippable.

## What counts as a meaningful commit

- Source code changes in `lib/`, `src/`, `app/`, `packages/`, etc.
- Tests in `test/`, `spec/`, `__tests__/`, etc.
- Documentation intended to ship (`README.md`, `docs/**`, user-facing markdown).
- Configuration that affects runtime behavior (`config/**`, `.env.example`, migrations).
- Build/CI configuration when that's the actual goal.

## What DOESN'T count (cross-check rejects these alone)

- `.claude/**` — agent profiles, skills, instructions. These configure the factory, not the product.
- Editor scratch files, `.DS_Store`, OS-specific cruft.
- Lockfiles alone with no manifest change (orphaned lockfile update).
- Whitespace-only or newline-only changes.

## When the validator says "pass"

Before declaring the mission complete, check:

1. `git diff --stat main...HEAD` — what paths actually changed?
2. If every path starts with `.claude/` (or similar settings-only paths), the mission is vacuous. The validator is wrong.
3. Fix: either make the real change and commit, or fail the mission with an honest gap ("impl op produced no source changes").

## Why this matters

- A vacuous PR opened on GitHub wastes reviewer attention and looks like the factory is producing noise.
- The cross-check guard (orchestrator `validate_pass_against_diff`) catches this at the validation phase and demotes the verdict to fail — but catching it earlier in impl is cheaper.
- A pattern of "impl declares success, only .claude/ changes committed" usually means the agent misunderstood the goal and generated a config tweak instead of a code change.

## How to check yourself before declaring done

- Run `git log --stat <base>..HEAD` on your working branch.
- At least one line in the stat should touch a source path (not a settings path).
- If not: reread the goal, locate the actual file(s) the change should live in, and make the edit.
