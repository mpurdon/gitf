# GiTF - Major Delegation Principle

## The Problem

In earlier iterations, the coordinator sometimes "just did the work" instead of delegating to worker agents. This defeats the entire purpose of the multi-agent architecture:

```
❌ WRONG: Major receives task → Major does the coding itself
✅ RIGHT: Major receives task → Major creates op → Major spawns ghost → Ghost does the coding
```

## Why This Happens

1. **Path of least resistance** - It's "easier" to just do it than set up delegation
2. **Context already loaded** - Major already understands the task
3. **No enforcement** - Nothing prevents Major from coding directly
4. **Unclear boundaries** - Major's role isn't strictly defined

## The Solution: Major Never Codes

### Hard Rule

**The Major MUST NOT:**
- Write application code
- Modify project files
- Run tests
- Make commits
- Push branches

**The Major MUST:**
- Analyze requests and break them into ops
- Create missions for related work
- Spawn ghosts and assign ops
- Monitor progress via links
- Summarize results to the user
- Handle escalations from stuck ghosts

### Enforcement Mechanisms

#### 1. Working Directory Isolation

The Major runs from `<workspace>/.gitf/major/` - a directory with NO project code:

```
~/my-factory/
├── .gitf/
│   ├── major/           # Major's workspace - NO CODE HERE
│   │   └── MAJOR.md     # Major's instructions
│   ├── config.toml
│   └── store/
└── myproject/           # Sector - Major can't touch this
```

#### 2. Major's CLAUDE.md

The Major's context file explicitly forbids coding:

```markdown
# Major Instructions

You are the Major of this Section. Your role is COORDINATION, not coding.

## You MUST NOT
- Write or modify any code files
- Run application tests
- Make git commits
- Touch any files in sector directories

## You MUST
- Break down user requests into discrete ops
- Create missions to bundle related ops
- Spawn ghosts to execute ops: `gitf ghost spawn --op <op-id>`
- Monitor ghost progress: `gitf ghosts`
- Report mission status to the user

## When a user asks you to build something:

1. Analyze the request
2. Create a mission: `gitf mission create "Feature name"`
3. Create ops for each discrete task
4. Spawn ghosts for each op
5. Monitor and report progress

## Example

User: "Add user authentication to myproject"

You should:
1. `gitf mission create "User Authentication" --sector myproject`
2. `gitf op create "Create User model" --mission <mission-id>`
3. `gitf op create "Implement login endpoint" --mission <mission-id>`
4. `gitf op create "Add session management" --mission <mission-id>`
5. `gitf ghost spawn --op <op-id>` for each op
6. `gitf mission show <mission-id>` to monitor
7. Report: "Mission 'User Authentication' complete: 3/3 ops done"

NEVER write the code yourself. ALWAYS delegate to ghosts.
```

#### 3. Sparse Checkout for Major

Major's git config excludes all sector directories:

```bash
# Major can only see .gitf/ directory
git sparse-checkout set .gitf/
```

#### 4. CLI Guardrails

The `gitf brief --major` command:
- Sets working directory to `.gitf/major/`
- Injects the "no coding" instructions
- Provides only coordination commands

#### 5. Audit Trail

Log when Major attempts file operations outside `.gitf/`:

```elixir
defmodule GiTF.Major.Audit do
  def check_file_access(path) do
    if outside_gitf_dir?(path) do
      Logger.warning("Major attempted to access #{path} - delegation required")
      {:error, :delegation_required}
    else
      :ok
    end
  end
end
```

### The Delegation Flow

```
User: "Fix bug #123 in myproject"
         │
         ▼
┌─────────────────────────────────────────────────────────┐
│ Major analyzes request                                  │
│                                                         │
│ > This is a coding task. I must delegate.               │
│ > Creating op for bug fix...                            │
│                                                         │
│ $ gitf op create "Fix bug #123" --sector myproject      │
│ Created op: op-abc123                                   │
│                                                         │
│ $ gitf ghost spawn --op op-abc123                       │
│ Spawned ghost: ghost-xyz789                             │
│                                                         │
│ > Ghost spawned. Monitoring progress...                 │
└─────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────┐
│ Ghost (ghost-xyz789) in shell worktree                  │
│                                                         │
│ - Reads op description                                  │
│ - Writes code to fix bug                                │
│ - Runs tests                                            │
│ - Commits changes                                       │
│ - Runs: gitf done --op op-abc123                        │
│ - Pushes branch, creates PR                             │
└─────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────┐
│ Major receives completion link                          │
│                                                         │
│ > Ghost completed op-abc123                             │
│ > Bug #123 fixed, PR created: #456                      │
│                                                         │
│ Reports to user: "Bug #123 fixed! PR #456 ready."       │
└─────────────────────────────────────────────────────────┘
```

### Parallel Work

When 10 bugs come in:

```
User: "Fix bugs #1-10 in myproject"
         │
         ▼
Major creates mission with 10 ops
         │
         ▼
Major spawns 10 ghosts (or batches based on config)
         │
         ├── Ghost 1 → Bug #1
         ├── Ghost 2 → Bug #2
         ├── Ghost 3 → Bug #3
         │   ...
         └── Ghost 10 → Bug #10
         │
         ▼
Ghosts work in parallel, each in isolated shell
         │
         ▼
Major monitors, reports: "Mission complete: 10/10 bugs fixed"
```

### Escalation Path

If a ghost gets stuck:

```
Ghost: "I can't figure out how to fix this bug"
         │
         ▼ (link to major)
         │
Major: "Ghost stuck on op-abc123. Options:
        1. Provide more context to ghost
        2. Reassign to different ghost
        3. Escalate to user for guidance"
         │
         ▼
Major sends link with hints, or asks user
```

## Implementation Checklist

- [ ] Major workspace at `.gitf/major/` with no code access
- [ ] Major's CLAUDE.md with strict "no coding" rules
- [ ] Sparse checkout excluding sectors from Major's view
- [ ] `gitf brief --major` sets up isolation
- [ ] Audit logging for Major file access attempts
- [ ] Clear CLI commands for delegation workflow
- [ ] Mission/op creation commands for Major
- [ ] Ghost spawn command that Major uses
- [ ] Link system for ghost → major communication
- [ ] Progress monitoring commands

## Summary

The key insight: **Make delegation the path of least resistance**.

If the Major can't see the code, it can't edit it. If it can't edit it, it must delegate. The architecture enforces the behavior we want.
