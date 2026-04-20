---
name: prefer-existing-utils-over-new
description: Before writing a new helper, utility, or abstraction, search the existing codebase for something that already does the job. Inline logic that duplicates an existing utility is a common source of drift and bugs. The right place to add something new is usually "next to the existing thing," not in a brand new file.
---

# Prefer existing utilities over new ones

Writing new code when existing code would do is one of the highest-signal failure modes in automated implementation. It creates drift (two ways to do the same thing), misses existing safeguards baked into the utility, and bloats the codebase.

## Before adding a new helper, check:

1. **Same directory, adjacent files.** If you're in `lib/gitf/ops.ex`, look at `lib/gitf/ops/` and `lib/gitf/ops_*.ex`. The helper you need may be two files over.
2. **Shared/util/common directories.** Most codebases have a `lib/util/`, `lib/shared/`, `lib/helpers/`, or similar. Grep it for the core operation you need.
3. **The existing callers of a similar pattern.** If ten other places in the code do `String.downcase() |> String.trim()` on user input, there's probably a `normalize_input/1` somewhere — find it, don't add an eleventh.
4. **Tests.** Existing test utilities often implement the exact thing you need for the production code too.

## Red flags that you're duplicating

- Writing `defp parse_foo/1` when a `Foo.parse/1` already exists two modules over.
- Rolling your own path-join logic when `Path.join/2` or a project helper does it.
- Writing a new JSON serializer branch when `Jason.encode/2` with options would work.
- Hand-rolling environment-variable lookup when `System.get_env/2` or a project config helper exists.
- Adding a new tagged-tuple error shape when the project already has `{:error, :not_found}` conventions elsewhere.

## What to do instead

- If the existing utility ALMOST does what you need, extend it (add an option, add a variant) rather than fork it.
- If the existing utility is in a bad location, move it before duplicating it.
- If no existing utility fits, write the new one IN the existing util location, not in a new file.

## Why this matters

- Drift costs compound: two implementations of the same idea means two places to fix when the requirements change.
- Existing utilities usually have hidden-but-important properties (error handling, nil safety, telemetry) that a fresh implementation loses.
- Every new file is a new thing someone has to read, test, and maintain.

## How to check yourself before declaring done

- `grep` or Glob for the function name you added, and for keywords describing what it does.
- If a teammate (or a future ghost) would reasonably expect this function in an existing location, it should be there, not in a new file.
