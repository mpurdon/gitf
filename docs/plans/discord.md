# Discord — the operator's phone, and the reply path back into the factory

*Plan of record, 2026-09-08. Origin: msn-629e74 held a design question for
twelve awake-hours overnight because nothing told the operator; the box
answered 503 the whole time and stayed up (~$0.40). The ministry plan
parked "operator notification while away" as an open item (`ministry.md`
§risks). This is that item, plus the reply direction the operator asked
for: answer the factory from the channel, keep a box awake from the
channel, steer a ministry from its own channel.*

## What the operator asked for

1. A notification when the factory is waiting on them (question, approval,
   a queued feature, a failure only they can unstick).
2. A warning *n* minutes before a box shuts down, and the ability to reply
   "keep it awake" — to that factory's Major, in words.
3. Channels: one for the **Cabinet**, one for the **overall plan**, one for
   **Aramaki** (GitHub-issue intake), and **one per ministry** that controls
   that ministry's factory specifically.
4. The MCP is the substrate — this is one of the reasons it had to be good.
5. Think about *what* talks to Discord and *how* LLMs read and handle the
   messages in both directions.

## What already exists (the seams — none of this is new architecture)

| Need | Seam | Where |
|---|---|---|
| Channel plugin contract, *docstring names Discord* | `GiTF.Plugin.Channel` — `start_link/1, send_message/3, send_notification/3, subscriptions/0` | `lib/gitf/plugin/channel.ex` |
| A finished channel to copy: config-or-disabled boot, urgent-vs-digest batching, inbound commands | `GiTF.Plugin.Builtin.Channels.Telegram` | `lib/gitf/plugin/builtin/channels/telegram.ex` |
| Every alert, with severity | telemetry `[:gitf, :alert, :raised]`; `Alerts.urgent?/1` | `alerts.ex:175, :199` |
| Channel-specific rendering, `:discord` already a documented format, unused | `GiTF.Formattable.format(data, :discord)` | `lib/gitf/protocol/formattable.ex` |
| Every factory operation, in-process, by name (82 tools) | `GiTF.MCPServer.Handlers.call(name, args)` | `lib/gitf/mcp_server/handlers.ex` |
| Any tool on any box, from the Cabinet | `GiTF.Cabinet.Proxy.call(slug, tool, args, wake:)` = `ministry_call` | `lib/gitf/cabinet/proxy.ex:16` |
| Answering with a named human | `Inquiry.answer(id, ans, answered_by: "…")` — "surfaces name themselves" | `inquiry.ex:592-602` |
| Keeping a box awake, bounded | `IdleStop.set(idle_min, duration_min, reason:)` — no unbounded hold exists by design | `idle_stop.ex:54` |
| An LLM agent loop with tools | `Studio.Session` (`kick_llm` → `classify` → tool calls → re-kick); `Chat.start_with_profile/2` with `ask_choice` | `studio/session.ex:264-310`, `cli/chat.ex:75` |
| Signed ingress per ministry, failure direction = queue | `CabinetHookController` + `Cabinet.Gate` | `web/cabinet_hook_controller.ex`, `cabinet/gate.ex` |
| Who is a person at the edge | `GiTF.Tailnet` (dashboard only; not plumbed into handlers) | `config/runtime.exs:171` |

Two gaps the design must close: `Handlers.call/2` hardcodes the actor to
`"mcp_operator"` (handlers.ex:26) — a Discord answer must record
`discord:<user>`; and `send_link`'s `from` is caller-asserted.

## Decisions

### D1. The bot lives on the Cabinet; Sections relay to it

A Discord bot needs a persistent gateway connection to *receive*
anything (button clicks, slash commands, free-text replies). Only one node
in the fleet is always on: the Cabinet. So:

- **Outbound:** a Section raises an alert as today → its Discord channel
  plugin relays it to the Cabinet (`POST /relay/<slug>`, HMAC-signed with
  the ministry's existing webhook secret — the same verification the
  GitHub ingress already does) → the Cabinet's bot posts it, with buttons.
  The Cabinet posts its own events directly.
- **Inbound:** the Cabinet's gateway receives the interaction → resolves
  which ministry the channel belongs to → executes via `Proxy.call` on
  that Section (waking it if the action needs it), or locally for
  Cabinet/plan/Aramaki actions.
- **Degraded path:** if the Cabinet is down, a Section can post *directly*
  to a Discord **incoming webhook** URL (no bot, no buttons, plain
  message with a dashboard link). That is M0 and stays as the fallback:
  the thing that makes idle-stop trustworthy must not itself depend on
  one more box being up.

Why not per-box bots: a sleeping box cannot hold a gateway; five boxes
would be five bots with five identities in one guild; and the reply to
"keep me awake" has to be delivered *before* the box sleeps, by something
that is still awake.

### D2. Channels mirror the authority split

| Channel | Owner | What arrives | What you can do |
|---|---|---|---|
| `#cabinet` | Cabinet | fleet wake/stop/health, cost rollup, mode changes, **inbox** (queued features), **sleep warnings** for every box | start an inbox entry, wake/stop a box, set a mode, keep a box awake |
| `#plan` | Cabinet (project state proxied from Sections) | project created/approved, roadmap items becoming missions, project completion, weekly digest | approve a project, pause/resume, ask "where are we" |
| `#aramaki` | Cabinet ingress + each Section's Aramaki | issue intake decisions (admitted / queued / ignored, with the rule that fired), `gitf:build` label events, admission-capacity blocks | admit a queued issue, drop one, ask why one was ignored |
| `#<ministry>` (`#home-affairs`, `#trajector`, …) | that Section | **questions** (`input_requested`, with mockups attached when they rendered), **approvals**, mission started/completed/failed, validation gaps, budget warnings, the sleep warning for *this* box | answer, approve/reject, kill, re-run, keep awake, and free-text to that factory's Major |

Inside a ministry channel, **one thread per mission** (created on
`quest_started`, archived on terminal). A question posts into its mission's
thread; the answer is a button in the thread. This keeps a busy factory
from flooding the channel and gives every mission a durable transcript a
human can scroll.

Slug ↔ channel is a registry field (`discord_channel_id` on the ministry
record); the Cabinet, plan and Aramaki channel ids live in the Cabinet's
`[plugins.channels.discord]` config.

### D3. Structured out, LLM in — and only where words arrive

**No LLM writes notifications.** Alerts, questions, approvals and sleep
warnings are structured data; they render deterministically through
`Formattable.format(…, :discord)` into embeds with components:

- a `choice` question → an embed per option (rationale, mockup attached
  as an image when `preview_url` exists) + a **select menu** of the option
  ids; `confirm` → two buttons; `text` → a "Reply in thread" prompt.
- an approval → Approve / Reject / Show diff buttons.
- a sleep warning → **Keep awake 1h / 4h / Sleep now** buttons.
- an inbox entry → Start / Drop.

Every button carries a `custom_id` = `<action>:<slug>:<entity_id>`; the
bot maps it to one tool call (`answer_question`, `approve_mission`,
`idle_stop_override`, `start_inbox_entry`, …) with the actor set to
`discord:<username>`. No model in the loop, no prompt to inject into,
~200 ms round trip.

**The LLM reads only free text**, and only in the places free text is
invited: a message in a ministry channel or mission thread, or a reply to
a bot post. That message goes to that channel's **agent** — a
`Chat.start_with_profile`-style loop (the `Studio.Session` pattern) with:

- a persona per channel kind (Cabinet steward / planner / intake officer /
  *this ministry's* Major-voice), built the way `Studio.Tools.system_prompt/0`
  is, with live state injected (open questions, active missions, the box's
  sleep countdown);
- a **curated tool subset**, not all 82: reads freely; writes only the ones
  the channel owns (a ministry agent gets `answer_question`,
  `approve_mission`, `kill_mission`, `start_mission`, `idle_stop_override`,
  `resume_mission`; never `register_ministry`), executed through
  `Proxy.call` for a ministry, locally for the Cabinet;
- the `ask_choice` discipline from `cli/chat.ex`: **every write is
  proposed as buttons first** ("Keep home-affairs awake for 2 h? [Yes]
  [No]"), so a natural-language request becomes a structured confirmation,
  and the confirmation — not the model — triggers the write. This is the
  same `confirm: true` contract the MCP already enforces, made visible;
- fast tier for the reply, `max_tokens` small, one turn unless it asked a
  question. Cost per message is cents.

"Keep it awake, I'll answer after dinner" → agent → proposes
`idle_stop_override(idle_minutes: 180, duration_minutes: 360)` as a button
→ tap → set on the Section → the idle-stop script honours the override on
its next tick. If the box sleeps before the tap, the tap wakes it
(`Proxy.call(…, wake: true)`) and applies it; the operator sees "woke
home-affairs (67 s), override set until 01:40".

**What the LLM never sees as instructions:** anything the factory relayed
from outside — issue bodies, PR review comments, webhook payloads — and
anything the bot itself posted. Inbound agent context is the operator's
message plus factory state the bot fetched. Guild, channel and user ids
are allow-listed in config; a message from anyone else is ignored, not
answered.

### D4. The sleep warning is a factory alert, not a Discord feature

`rel/gitf-idle-stop.sh` gains one line: when the idle countdown reaches
`IDLE_MINUTES − WARN_MINUTES` it calls the daemon
(`POST 127.0.0.1:4000/api/v1/idle/warn?minutes=N`, loopback only), and the
daemon raises `idle_stop_imminent` (severity `:high`, dedup key = the idle
episode's start time, so one warning per episode). That alert flows like
any other — Telegram gets it today, the log gets it, Discord gets it with
buttons. Nothing about the warning is Discord-specific, which is the test
that it is at the right altitude. `WARN_MINUTES` defaults to 10.

Held missions no longer keep a box awake (0.65.279), so the warning is the
last chance to say "wait" — and the answer wakes the box anyway.

### D5. Actor identity is plumbed, not assumed

`Handlers.call/3` gains `actor:` (default `"mcp_operator"`), threaded to
`Inquiry.answer(answered_by:)`, `Override.approve/2`, the audit log and
`send_link`'s `from`. The Discord bridge passes `"discord:<username>"`;
the tailnet edge can pass the login it already resolves. Same rule as
today: an actor must never start with `"auto"`. `send_link` from Discord
sets `from` itself; a user cannot spoof another surface.

## Implementation: `GiTF.Plugin.Builtin.Channels.Discord`

Library: **Nostrum** — the standard Elixir Discord library (gateway,
REST, interactions/components, rate-limit handling). It is a real
dependency (an OTP app with its own supervision tree) but hand-rolling the
gateway (heartbeats, resume, sharding, rate limits) is the bigger risk;
the Telegram plugin's polling bug (`external-risk-2026-08-15.md`) is the
cautionary tale for writing transports by hand. Gateway intents: guilds,
guild messages, **message content** (needed for free text; toggled in the
developer portal, fine under 100 guilds).

Module shape, mirroring Telegram:

```
Discord (GenServer, @behaviour GiTF.Plugin.Channel)
  init:        config or {:disabled}; attach [:gitf, :alert, :raised];
               subscribe "section:alerts", "link:major"
  outbound:    alert → Formattable(:discord) → Nostrum.Api.create_message
               (urgent immediately; the rest in the 30 s digest, as Telegram)
  interaction: custom_id → tool call with actor → edit the message with
               the outcome (buttons disabled, "answered by @matt 21:04")
  message:     allow-listed channel + user → Discord.Agent for that channel
Discord.Relay (Cabinet-side controller): POST /relay/:slug, HMAC per
               ministry (reuses cabinet_hook_controller's verifier)
Discord.Agent (one per channel/thread, Registry-keyed, idle-timeout):
               the Studio.Session loop with the channel's profile
Formattable impls for: Alert, Inquiry (question), Approval, IdleWarning,
               InboxEntry, MissionEvent
```

Config:

```toml
# Cabinet
[plugins.channels.discord]
token_env = "DISCORD_BOT_TOKEN"        # name only, like every other secret
guild_id = "…"
channels = { cabinet = "…", plan = "…", aramaki = "…" }
operators = ["matthew"]                # allow-listed usernames
agent_tier = "fast"

# each Section
[plugins.channels.discord]
relay_url = "https://gitf-cabinet.tailcf2c46.ts.net:8443/relay/home-affairs"
fallback_webhook_env = "DISCORD_WEBHOOK_URL"   # M0 path, used when the relay fails
```

## Status (2026-09-10)

**M1 built** (`GiTF.Cabinet.Discord.{Bot,Consumer,Guild,Render,Actions}`,
`GiTF.Plugin.Builtin.Channels.Discord`, `POST /relay/:slug`, D4's
`idle_stop_imminent` via `GiTF.IdleStop.Warning`, D5's `Handlers.call/3`
actor with `params.actor` over the MCP RPC and `Proxy.call(actor:)`).
One change to the design below: the bot **provisions its own channels**
(`Cabinet` and `Ministries` categories + fixed channels on connect,
`#<slug>` on `register_ministry`, a thread per mission), so the config is a guild id, not four channel ids.
M0's fallback webhook is inside the relay plugin (`DISCORD_WEBHOOK_URL`,
used only when the relay fails). Operator setup is in OPERATING §9c.
**Deployed 2026-09-10 (0.65.332 on both boxes):** bot "Cabinet" in the
operator's guild `1547247808145268869`; `Cabinet` and `Ministries`
categories provisioned; factory relays through the funnel's `/relay`;
first sleep warning rendered end to end (factory → Cabinet → embed with
buttons, 3 ms). Lesson: Discord drops `Manage Channels` from an invite
unless granted explicitly — set it on the bot's role in Server Settings.

**There is no LLM in M1.** Outbound is deterministic rendering, inbound is
a `custom_id` → tool lookup. Free text in a channel is ignored until M2.
Not yet: M2 (free text → agent), M3 (mockup images, slash commands, quiet
hours), M4 (voice), `#plan` / `#aramaki` content (channels exist, nothing
posts there yet).

## Milestones

**M0 — this week, no bot.** `[observability] discord_webhook_url`: a
Discord-format sink beside the generic webhook (Discord wants
`{content, embeds}` not `{text, type}`), rendered through
`Formattable(:discord)`, severity-gated like the webhook. Questions,
approvals and failures reach the phone with a dashboard link. Plus D4's
`idle_stop_imminent`. One evening; instant value; the fallback path M1
keeps.

**M1 — the bot.** Nostrum on the Cabinet; relay endpoint; channel per
ministry from the registry; embeds with buttons for question / approval /
sleep warning / inbox; D5 actor plumbing; mission threads. Requires the
Cabinet box to be **on** — it is on the tailnet (`gitf-cabinet`) but
currently offline; that is the ~$10/mo the ministry plan already priced,
and it is the operator's spend call.

**M2 — words.** `Discord.Agent` per channel with curated tools and the
button-confirmed-write discipline; `#plan` and `#aramaki` personas;
weekly digest (the one place an LLM *writes* — fast tier, from the ledger).

**M3 — polish.** Mockups attached as images (needs Playwright's browser in
box provisioning — msn-629e74's question shipped without previews for
exactly that reason); `/gitf` slash commands mirroring the CLI; a
per-ministry "quiet hours" so a client box's channel does not page at 03:00.

**M4 — voice.** Operator direction (2026-09-10): the bot's permissions were
granted wide on purpose so it can join voice channels and take voice
control. The pieces exist: Nostrum does voice natively (join, receive,
play), and the studio already runs a bidirectional voice loop
(`GiTF.Studio` + Gemini Live, voice milestone M4 of the Aramaki plan).
Shape: the Cabinet joins a voice channel on request; audio goes to that
channel's M2 agent through the studio's voice session; the agent answers
by voice AND every write it wants is still proposed as buttons in the
text channel — voice never bypasses the tap. Not started; after M2.

## Risks and the honest bits

- **One more always-on thing.** The Cabinet was already the fleet's front
  door; the bot makes it load-bearing for the *reply* path too. The
  fallback webhook keeps *notification* independent of it.
- **Discord as a control plane.** A compromised Discord account becomes an
  operator. Mitigations: allow-listed user ids, writes always
  button-confirmed and audited with the Discord identity, no
  `register_ministry`/`set_ministry_mode` from Discord without a second
  factor (the dashboard on the tailnet), and every action still runs
  under the Section's own gates (approval posture, budget cap).
- **Prompt injection through relayed content.** D3's rule: relayed external
  text is never agent input. The relay carries structured alert fields,
  not raw payloads.
- **Nostrum's footprint** on a t4g.micro: modest (a few processes, one
  WebSocket), but measure memory after M1 before adding agents.
- **Rate limits.** Discord's are generous for one guild; the existing
  digest batching handles bursts (a run-13-style failure cascade must not
  post forty embeds).

## What this does *not* do

It does not move any decision into Discord that the factory does not
already put in front of a human. Every button maps to a tool that exists
and requires the same confirmation today. It does not let an LLM act on
a ministry without a person tapping. And it does not replace the
dashboard: threads are a transcript, the Catwalk is still where you read
a plan.
