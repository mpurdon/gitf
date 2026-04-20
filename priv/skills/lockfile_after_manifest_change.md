---
name: lockfile-after-manifest-change
description: When you edit a package manifest (package.json, Gemfile, mix.exs, Cargo.toml, requirements.txt, pyproject.toml), the matching lockfile must be regenerated and committed in the same change. Skipping the lockfile leaves CI/other developers on a different resolved dependency tree than you intended.
---

# Lockfile after manifest change

A manifest edit that doesn't include a lockfile update is almost always a bug. The lockfile is what the ecosystem's install step actually reads.

## When this matters

Any commit that modifies one of:

- `package.json` → `package-lock.json` (npm) or `pnpm-lock.yaml` or `yarn.lock`
- `Gemfile` → `Gemfile.lock`
- `mix.exs` (dependency list) → `mix.lock`
- `Cargo.toml` (dependencies) → `Cargo.lock`
- `requirements.txt` → no separate lockfile (pip freeze captures it)
- `pyproject.toml` (dependencies) → `poetry.lock` or `uv.lock` or `pdm.lock`
- `go.mod` → `go.sum`

## What to do

1. Make the manifest edit.
2. Run the package manager's install/resolve command (e.g. `npm install`, `bundle install`, `mix deps.get`, `cargo build`).
3. `git status` — verify the lockfile is now dirty.
4. Commit the lockfile change **in the same commit** as the manifest change.

## Why this matters

- CI builds may cache node_modules / deps but re-resolve against the lockfile. A manifest-without-lockfile change can cause CI to pick a different version than your local dev, breaking reproducibility.
- Other developers pulling the branch will get a conflict-free manifest but stale lockfile, then silently install a different version, then hit mysterious runtime bugs.
- Security: lockfiles pin sub-dependencies. Missing lockfile updates can allow supply-chain drift.

## How to check yourself before declaring done

- `git status` should show both files dirty.
- `git log -1 --stat` on your commit should include both paths.
- If lint/CI flags a manifest-only change, do not force-merge. Regenerate the lockfile locally and amend.
