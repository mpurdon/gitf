# System One (Jev) — what it decides, and why not an LLM

**Status (2026-09-21):** one decision in production use, behind two flags.
The API key is live on the box (`GITF_SYSTEM_ONE_API_KEY`, resolved from SSM
Parameter Store). Everything here is default-OFF; see [Operating](#operating).

Code: `lib/gitf/system_one.ex` (wrapper), `lib/gitf/ghost/failure_class/judge.ex`
(the one consumer), `lib/gitf/ops.ex` (`fail/2`, the call site).

---

## 1. What a System One model is, and what it is not

TypeSafe's Jev takes a **state** and a map of **typed questions**, and returns
**typed answers with a calibrated probability distribution**. It writes no
prose, calls no tools, and cannot be asked to do either.

Three question types:

| Type | Asks | Returns |
|---|---|---|
| `choice` | pick one of `criteria` (option name → description) | the option + `confidence` + the full distribution |
| `score` | rate against ordered levels | a *continuous* score, which may sit between levels |
| `noul` | is this yes/no claim true? | a probability — no separate confidence, because the probability *is* the uncertainty |

Jev ingests the state once and evaluates every question against it in parallel,
so **five questions in one call cost barely more than one**. Pack them; don't
make a call per decision.

That narrowness is the entire reason it is in the codebase. It is not a smaller,
cheaper LLM. It is a different instrument, and it answers a question generative
models structurally cannot.

## 2. The decision it makes today

**Classifying the failures the signature matcher could not name.**

`GiTF.Ghost.FailureClass` matches substrings. That is precise on the phrasings
it knows and blind to every other one, so novel wording lands in `:unknown` —
and `:unknown` is where two unrelated things pile up together: *the factory's
own defects* and *ghosts producing bad work*. Telling those apart is the job.

### The mechanism, exactly

```
Ghost.Worker dies → Ops.fail/2
                      ├─ FailureClass.classify(reason)        substring match
                      ├─ if :unknown and enabled → Judge.refine/2   ← Jev
                      └─ Archive.update(:ops, …)              store class + verdict
```

| Property | Value | Why |
|---|---|---|
| **Trigger** | `:unknown` only | A signature hit is never revisited. Those patterns were written narrow on purpose; re-opening a decision that is already right can only make it wrong. |
| **Question** | one `choice` over 8 criteria | The descriptions are the whole interface — the model never sees the question id. They're written to *contrast* with each other, not to define each class in isolation. |
| **Input** | the reason text, trimmed to 8 000 chars | Non-binary reasons are `inspect`ed — the same input the signature matcher sees, so both judge the same thing. |
| **Timeout** | 2 s | This runs on a path that has *already failed*. A dying ghost worker can afford two seconds; nothing should wait longer to be told something it already has a usable answer for. |
| **Promotion** | ≥ 0.75, and ≥ 0.90 for `fatal` | The threshold follows the blast radius (below). |
| **Fallback** | `:skip` → stays `:unknown` | Off, throttled, timed out, malformed, or unsure all land here, and `:unknown` is exactly today's behaviour: retried, charged to capability. |
| **Record** | verdict + confidence + full distribution, promoted or not | The only way to ask later whether the calibration held. |

### Two vocabularies, deliberately

The judge answers into a **wider** vocabulary than the taxonomy it feeds:

- **Promotable** (exist in `FailureClass`): `provider_error`, `timeout`,
  `fatal`, `no_changes`, `blocked`.
- **Never promoted**: `factory_defect`, `bad_work`, `unknown`.

`factory_defect` and `bad_work` have no counterpart in the taxonomy and change
no control flow at all. They ride along as a recorded verdict because they
answer a question nothing in the factory could answer before: **how many of my
failures are my own bugs?**

### Why `fatal` has its own threshold

The consequences differ by an order of magnitude:

- A wrong `provider_error` → one attempt charged to the wrong budget.
- A wrong `fatal` → **the op is abandoned with its retries unspent.**

So 0.90 for `fatal`, 0.75 for everything else. The threshold follows the blast
radius, not a general sense of fussiness.

### Where the call sits, and why it matters

`Judge.refine/2` runs **before** the `Archive.update`, not inside it. An update
function holds the collection's writer, and a third party's latency in there
would stall every other op's write behind it.

Blocking at all is affordable only because `Ops.fail/2` has **exactly one
caller** — `Ghost.Worker`, in a process that is already dying. Nothing else
calls it, and in particular the Major does not: putting a third party's latency
in front of the orchestrator is a different proposition entirely.

## 3. Why this and not a generative LLM

The short version: **an LLM states "provider_error" with the same flatness
whether it is certain or guessing.** A calibrated distribution gives the third
answer neither a regex nor a generative verdict can produce — *I do not know*,
as a number you can threshold on.

Spelled out, four properties had to hold at once:

**a. The answer set is closed and small.** Eight options, fixed, known at
compile time. Free-text generation is strictly worse here: you get a string you
must then validate against the set anyway, plus a parsing failure mode that
doesn't exist when the type system guarantees one of eight.

**b. The uncertainty must be machine-readable.** This is the load-bearing one.
The factory needs to *act differently* on a confident answer and an unsure one,
and it needs to draw that line differently for `fatal` than for
`provider_error`. You can ask an LLM to emit a confidence score; what comes back
is a token sequence shaped like a number, not a calibrated probability — it is
not derived from the distribution and does not behave like one under
thresholding. Jev's confidence comes from the shape of the distribution itself,
which is what makes 0.75-vs-0.90 a meaningful distinction rather than
superstition.

**c. It must fail closed, cheaply.** The conservative answer here is "leave it
`:unknown`", which is free and already correct. A judge that fails *open*
converts a network blip into a permissive decision — precisely the defect shape
the 2026-08-28 BEAM audit found in the cost cap and the security scan. A 2 s
timeout into a known-good fallback is only sane when the fallback costs nothing,
which it does here.

**d. The economics have to permit judging things you currently don't judge.**
Jev bills **input tokens only**, at roughly **$0.042 per million** (output is
free). A 2 000-token judgement is about **$0.00008** — eight thousandths of a
cent. That is what makes it reasonable to classify failures the factory
previously left in a pile. The same work through a generative model, priced with
output tokens, would be a line item you'd have to justify per mission.

Any decision missing one of those four is the wrong shape for this tool.

## 4. Why not just extend the regex

Because the residue is the point. `FailureClass` is kept narrow deliberately —
a false `:fatal` costs an op its whole retry budget, so broad patterns are worse
than no pattern. Widening the substrings to cover novel phrasings trades that
precision away on *every* failure, including the ones currently classified
correctly.

The judge touches only what the matcher declined to name. The precise mechanism
keeps its precision; the probabilistic one gets the pile it was already failing
to sort.

## 5. Considered and rejected: the Discord tool router

Routing a Discord message to one of ~85 MCP tools looks like the same shape as
the above — closed answer set, natural-language input, a classification. It was
rejected, on structural grounds.

`GiTF.Cabinet.Discord.Toolbelt` already decides this **by construction**:

- Only names in `persona.tools` are *built* as callable tools. A tool that is
  not built cannot be called however the conversation goes — as opposed to a
  prompt, or a classifier, being asked not to pick it.
- The ministry slug is **captured in each callback's closure**, not present in
  the tool's parameter schema. The Major in `#home-affairs` cannot reach
  `trajector` because no code path exists.

Inserting a probabilistic router would take a decision currently made by the
type system and make it a confidence threshold. That is a strict downgrade:
structural guarantees don't have a 5 % tail. **A calibrated classifier is an
upgrade over a guess and a downgrade over a proof.** Reach for it only where the
alternative is a guess.

## 6. The test for the next candidate

Use System One where **all four** hold:

1. The answer is one of a **fixed, small set** — or a position on an ordered
   scale, or a yes/no probability.
2. The factory would **act differently** on a confident vs. an unsure answer,
   and "unsure" has a safe, cheap default.
3. The decision is **not already structural.** If the type system, an
   allow-list, or a closure decides it today, leave it alone.
4. It is a decision the factory currently makes **badly or not at all** —
   substring matching, or an LLM stating a verdict flatly.

Named in `system_one.ex` as plausible, none built: which sector a mission
belongs to; whether a diff satisfies its goal. Both pass (1) and (4); neither has
been worked through for (2).

## 7. Operating

**Three switches, all required:**

```elixir
config :gitf, :system_one_enabled, false   # [features] system_one_enabled
config :gitf, :failure_judge_enabled, false # [features] failure_judge_enabled
# + GITF_SYSTEM_ONE_API_KEY (or TYPESAFE_API_KEY)
```

`SystemOne.enabled?/0` requires **both the flag and a key**: the flag alone on a
keyless box makes every judged decision pay the timeout before falling back, and
a key alone should not start spending because it happens to be in the
environment. `Judge.enabled?/0` then needs its *own* flag on top, so the pilot
can be switched off without disturbing anything else built on System One.

Flags live in the config's `[features]` table and apply on reload — no restart.
The **key** comes from the environment or SSM only, never config (config is
readable by anything that can read config), and systemd reads `EnvironmentFile=`
at unit start, so a *new key* needs a restart even though the flag next to it
does not.

**Two standing rules:**

- **Fail closed, always.** Every caller supplies the conservative fallback — the
  answer the factory would have reached without the judge.
- **Never chat-settable.** Deliberately absent from `GiTF.Config.Settable`.
  Starting a metered third-party spend line is not something a chat message
  should be able to do.

**Evaluating the pilot.** Every judgement is stored on the op as
`failure_judgement` (verdict, confidence, full distribution) whether or not it
was promoted, and the verdict is carried into `judged_7d` on `factory_status`.
So "did the calibration hold?" is a query against the Archive, not an opinion —
which is the whole reason it was built as a pilot rather than as a behaviour
change.
