# Simulator Test Plan

The simulator runs the full GiTF pipeline (orchestrator + worker + git +
Archive) against a scripted LLM client so we can lock in failure-mode
behavior without burning real credits.

It is the **reliability gate** for the project: any change that touches
the orchestration pipeline must keep these scenarios green, and any new
class of failure mode the system claims to handle should land with a
new simulator scenario that proves it.

## Run it

```sh
mix test test/simulator/ --include simulator
# or with tick-by-tick state diffing:
GITF_SIM_TRACE=1 mix test test/simulator/ --include simulator
```

Single test:

```sh
mix test test/simulator/happy_path_test.exs --include simulator
mix test test/simulator/edge_cases_test.exs:21 --include simulator   # by line
```

Whole suite is ~3 minutes. Zero LLM credits.

## When to add a scenario

Add a simulator scenario when you ship code that **changes how the
pipeline reacts to a specific input or failure**. Examples:

- Adding a new phase or reordering phases
- Changing how the orchestrator decides to retry / fail / advance
- Adding a guard against a class of failure (e.g. publish-failure
  propagation, cost cap, validator cross-check)
- Fixing a silent-stall bug — write a scenario that reproduces the
  stall, then ensure your fix turns it green

**Do not** use the simulator for:

- Pure-function tests (use unit tests)
- LLM prompt content tests (use phase-prompt unit tests)
- Component-level tests of one module (use focused integration tests)

The simulator is for **whole-pipeline behavior under specific
conditions**.

## How to write one

Every scenario follows the same shape:

```elixir
defmodule GiTF.Simulator.MyScenarioTest do
  use ExUnit.Case, async: false

  alias GiTF.Test.{ScriptedLLMClient, Simulator}

  @moduletag :simulator

  test "<observable assertion under the failure condition>" do
    {:ok, sim_ctx} =
      Simulator.setup_scenario(
        rules: [
          # one entry per LLM phase prompt the mission will hit
          %{match: ~r/# Triage Phase/, response: ScriptedLLMClient.ok_text(...)},
          # ...
        ],
        sector_name: "myscen-#{:erlang.unique_integer([:positive])}",
        files: %{"app/main.js" => "// initial\n"}
      )

    on_exit(fn -> Simulator.reset!(sim_ctx) end)

    {:ok, mission} = Simulator.create_mission(sim_ctx, goal: "...")

    {:ok, outcome} = Simulator.run(sim_ctx, mission.id, max_ticks: 200)

    assert outcome.status == "completed"   # or "failed", or whatever the
                                            # failure mode demands
  end
end
```

### Checklist

1. **One scenario per failure mode.** Don't bundle multiple modes into
   one test — when it breaks, you want a single, specific failure mode
   pointed at.
2. **Use `on_exit` for cleanup.** `Simulator.reset!/1` is sector-scoped
   and idempotent. Without it, the next scenario's Archive will see
   stale records.
3. **Cover every LLM call you expect to fire.** Unmatched calls bump
   the unmatched counter (test #4 in `failure_scenarios_test.exs`)
   — assert `ScriptedLLMClient.unmatched_count() == 0` if you want
   strict matching.
4. **Pick your `max_ticks` budget honestly.** Each tick is 100ms.
   Fix-loops + retries can need 600–900 ticks. Use `{:timeout, info}`
   pattern to surface stalls vs flunk on outright wrong outcomes.
5. **Always assert against `outcome.status`,** not just "test didn't
   crash." Phantom successes are exactly the bug class this suite
   exists to catch.

## Existing scenario inventory

| File | # tests | What's covered |
|---|---|---|
| `happy_path_test.exs` | 1 | Full GH-issue → publish flow reaches `completed` |
| `failure_scenarios_test.exs` | 3 | Publish-fail propagation; empty-response retry; unmatched-rule signal |
| `more_scenarios_test.exs` | 4 | Triage strong/weak evidence; hallucinating validator; provider transient error |
| `edge_cases_test.exs` | 3 | Per-mission cost cap; ghost mid-op crash; merge-conflict recovery |

11 scenarios total. Each takes 7–25s. Suite total: ~3 min.

## Reusable primitives

### Building rules

```elixir
# Plain text response
ScriptedLLMClient.ok_text("model output goes here")

# Phase artifact wrapped in JSON fence (matches PhaseCollector parser)
ScriptedLLMClient.ok_text(
  ScriptedLLMClient.json_artifact(%{"overall_verdict" => "pass"})
)

# Empty response (triggers worker retry path via :empty_response)
ScriptedLLMClient.empty_response()

# Provider error (worker fallback / fail-fast path)
{:error, {:api_error, :empty_response}}
{:error, {:api_error, :timeout}}
```

### Rule fields

```elixir
%{
  match: ~r/# Triage Phase/,         # Regex or substring match against prompt
  response: {:ok, %ReqLLM.Response{}},  # what the mock returns
  consume: true,                     # default; remove rule after first match
  side_effect: fn -> ... end         # optional; runs after rule matches
}
```

`consume: false` keeps the rule in the pool for repeat matches — useful
for retries / fix-loops where the same prompt fires multiple times.

### Side effects (the heart of failure injection)

A `:side_effect` is a 0-arity function that runs synchronously after
the mock matches. It can do anything: commit files, kill a process,
insert Archive records, flip an ETS table.

Built-in side-effect helpers:

```elixir
# Commit a file in the impl ghost's worktree (so files_changed > 0)
Simulator.simulate_impl_commit(mission_id, [{path, content}])

# Same, but auto-discovers the mission via sector_id at call time.
# Use this when scenario rules are built BEFORE the mission exists.
Simulator.impl_commit_hook(sector_id, files)
```

For arbitrary side effects (kill a worker, insert a cost record,
commit conflicting state to main): write the side effect inline in the
rule. See `edge_cases_test.exs` for examples of each.

### Composing side effects

Two side effects on the same rule? Wrap with a helper:

```elixir
chained = fn ->
  if is_function(previous, 0), do: previous.()
  hook.()
end
```

The `attach_*_hook/1` helpers in `more_scenarios_test.exs` and
`edge_cases_test.exs` show this pattern for retroactively adding hooks
to existing scenario rules.

### Live scenario mutation

You can edit the scenario between `setup_scenario` and `run`:

```elixir
%{rules: rules} = :sys.get_state(ScriptedLLMClient)
updated = Enum.map(rules, fn r -> ... end)
{:ok, _} = ScriptedLLMClient.start_scenario(updated)
```

This is how the `attach_*_hook/1` patterns work — they read the live
rules, splice in side effects, and replay the updated set.

### Pre-seeded Archive state

Records you insert into `:missions`, `:ops`, `:ghosts`, `:costs`, etc.
before calling `Simulator.run/2` are visible to the orchestrator.
`reset!/1` scopes cleanup by `sector_id`, so seeded records tied to
the test sector get purged afterwards.

Common pre-seed patterns:

```elixir
# Pre-create a fake op + cost record so Costs.for_quest sees it.
# Used by the cost-cap test.
{:ok, fake_op} = GiTF.Ops.create(%{...})
GiTF.Archive.insert(:costs, %{ghost_id: fake_op.ghost_id, ...})

# Set sync_strategy on the sector before mission creation.
GiTF.Archive.update(:sectors, sim_ctx.sector.id, fn s ->
  Map.put(s, :sync_strategy, "pr_branch")
end)
```

## Coverage gaps + how to add them

Two failure modes are deferred because they need infrastructure outside
the LLM/git layer. Sketches for each:

### PR idempotency reuse

The orchestrator calls `gh pr view --head <branch>` to detect an
existing PR before creating a new one. To test the idempotent path,
the simulator needs to fake `gh`. Two approaches:

- **PATH-based mock**: prepend a temp dir containing a `gh` shell
  script that returns canned JSON, set during `setup_scenario`.
- **Code-level mock**: extract the `gh` invocation into a behaviour
  (`GiTF.GH.Client`) and swap it out via Application config, mirroring
  the existing `LLMClient` pattern.

The PATH approach is simpler but flakier (relies on `System.cmd`
honoring `PATH`). The behaviour approach is cleaner but requires a
production refactor.

### Daemon restart / supervision-tree cycling

Restarting the `GiTF.Supervisor` mid-test would disrupt other
processes shared with the host application. Possible approaches:

- **Boot a sub-application in test**: start a second `GiTF.Application`
  instance with a distinct registry / supervisor name, restart only
  that. Heavy lift.
- **Targeted restart of one ghost worker**: simulate a daemon restart
  of a single phase's worker by killing its pid and asserting the
  recovery code path picks it up from `:checkpoints`. Lighter-weight,
  covers the same code path.

The targeted-restart variant is the natural next addition — it would
slot into `edge_cases_test.exs` alongside the existing ghost-crash
test.

## Architecture notes

### Why the simulator uses the running app's supervision tree

`GiTF.StoreCase` restarts the Archive, which disconnects `GiTF.Major`
and `GiTF.MissionSupervisor` from the data they need to spawn ghosts.
The simulator instead works against the application-started supervision
tree and scopes all writes/cleanup to a unique sector.

This means simulator tests are **not async-safe** — they run with
`async: false` and depend on the host app's singleton processes.

### Why we ensure a `.gitf/` root

`spawn_phase_ghost_inner` calls `GiTF.gitf_dir()` which requires a
`.gitf/config.toml` somewhere on disk. `setup_scenario` creates one in
a temp dir per scenario and points `GITF_PATH` at it. `reset!/1`
restores the previous `GITF_PATH` value.

### Why we don't use `Mox`

Mox requires explicit expectations and verification. The simulator
needs the LLM client to handle prompts the test author didn't fully
predict (e.g., the `Implement:` prompt in a fix-loop scenario fires
N times for varying N). The scripted-rule pattern with regex matching
fits that better.

### Side-effect timing

Side effects run **synchronously inside the LLM call's task**, AFTER
the mock returns the response to the agent loop. This means:

- A side effect can mutate state the worker will read in the next step
  (e.g., commit a file before `mark_success` reads the diff).
- A side effect can kill the worker mid-call by sending it `Process.exit`.
- A side effect cannot delay the response — the LLM call returns
  immediately after the side effect completes.

### What `Simulator.run/2` does between ticks

Each tick:

1. Sleeps `@tick_interval_ms` (100ms).
2. Reads the mission record + ops.
3. If status is terminal (`completed | failed | killed | closed`),
   returns the outcome.
4. Otherwise, calls `GiTF.Major.Orchestrator.advance_quest/1` to nudge
   the orchestrator. (The mock doesn't trigger any link_msg events the
   way real ghosts do, so we manually drive advance.)

`max_ticks` is the upper bound — if the mission doesn't reach a
terminal state in time, you get `{:timeout, info}` with a snapshot
of the mission, ops, and LLM call log for debugging.
