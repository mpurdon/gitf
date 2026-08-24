# GiTF — Ghost in the Factory

Multi-agent orchestration system in Elixir/OTP. This repo is the **source**.

## Read this before operating the factory

**[`docs/OPERATING.md`](docs/OPERATING.md) is the operating runbook.** Read it
whenever the task is to run, watch, or debug the *running* factory — creating
missions, chasing a failure, touching the box. Everything below is just the
orientation you need to know that you need it.

## The running factory is not here

The factory runs on an EC2 box reachable only over the tailnet at
**https://factory.ghostinthefactory.com**. The local `gitf` CLI and the `gitf`
MCP server are both in **remote mode** — every command drives that box, not a
local factory. Editing code here changes nothing about the running factory
until a release is installed on the box.

**The box powers itself off when idle.** Every MCP tool failing with
`remote factory: Connection timed out` means *asleep*, not *broken*. Run
`gitf wake` (~60s), then `health_check`. Waking is cheap and self-reversing.

## Use the MCP, not the box

Default to `mcp__gitf__*` for anything about factory state — status, version,
missions, ops, ghosts, costs, host memory, disk, provider health. The tools
return structured state, and the operator watches the session, so an MCP call
is legible where a curl pipeline or an SSM round-trip is not.

Shelling into the box is the last resort. It is genuinely required only for
installing a release, boot-time env in `/etc/gitf/gitf.env`, systemd/tailscale,
and AWS-side work — see the coverage table in `docs/OPERATING.md` §2.

## Two facts that catch people

- **`create_mission` does not start the mission.** Call `start_mission`
  separately. Both need `confirm: true`.
- **Most of the intelligence layer is default-off** — skills, outcomes,
  autonomy tiers, knowledge injection, LSP validation, workflow inference,
  tournaments, Aramaki. Don't assume any of it is running.

## When a mission fails

Never rescue the mission. Root-cause the **factory** defect, fix that, then
re-run the same mission unchanged as the test. Postmortems: `docs/audits/`.

## Working in this repo

```sh
mix test          # heavy suites (simulator, e2e, llm) are tag-excluded by default
mix format
mix escript.build # dev CLI binary → ./gitf
```

- Test in `~/Projects/gitf-test`, never in this repo.
- Never set `GITF_PATH`; use `gitf -w <path>`.
- A pre-commit hook auto-bumps the version and `git add`s `mix.exs`.

## Further reading

| Doc | What |
|---|---|
| [`docs/OPERATING.md`](docs/OPERATING.md) | Running the factory (start here) |
| [`docs/deploy-aws.md`](docs/deploy-aws.md) | Provisioning and deploying the box |
| [`docs/audits/`](docs/audits/) | Mission postmortems and readiness audits |
| [`specs/ARCHITECTURE.md`](specs/ARCHITECTURE.md) | System design and schema |
| [`specs/GLOSSARY.md`](specs/GLOSSARY.md) | Terminology (sector, ghost, op, mission) |
| [`specs/DELEGATION.md`](specs/DELEGATION.md) | Major delegation principle |
