#!/usr/bin/env bash
# Runtime smoke probe for the cora sector: build the real app from this
# worktree, launch it headless under WebDriver, and click through every
# reachable control. Static gates prove the code compiles; THIS gate proves
# the software runs. Born from PR #6: typecheck, cargo test, and LLM review
# all passed while the app crashed on first open of the new drawer (serde
# skip_serializing_if omitted empty maps the TS bindings promised were
# always present).
#
# Runs inside the validation worktree (cwd = worktree root), exits nonzero
# on any failure; the last lines of output are the verdict the validation
# prompt sees.
set -uo pipefail

say() { echo "[cora-smoke] $*"; }

export PATH="/var/lib/gitf/.cargo/bin:$PATH"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/var/lib/gitf/cargo-target}"
# webkit2gtk under Xvfb needs compositing off or it renders nothing.
export WEBKIT_DISABLE_COMPOSITING_MODE=1

WT="$(pwd)"
ART="$WT/.gitf-probe"
mkdir -p "$ART"

# Evidence must outlive the worktree: when a mission seals, the orphan
# sweep deletes the ghost's worktree and takes .gitf-probe with it —
# run 29's PASSING screenshots were gone within minutes of being written.
# Mirror artifacts to a mission-scoped keep dir on the host.
KEEP="/var/lib/gitf/probe-artifacts/$(basename "$WT")-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$KEEP" 2>/dev/null || KEEP=""
keep_artifacts() {
  [ -n "$KEEP" ] && cp -f "$ART"/* "$KEEP"/ 2>/dev/null
  [ -n "$KEEP" ] && say "artifacts kept at $KEEP"
}

# Only ONE probe may run per host: the app's devUrl port (1420) is baked
# into the binary, so concurrent probes fight over it. Take an exclusive
# lock BEFORE sweeping — the sweep kills any http.server on :1420, and
# run 30's overlapping validation rounds had the second probe killing the
# FIRST probe's server, leaving that app on "Connection refused" with no
# clickable UI (which the monkey then correctly, uselessly, reported).
# The lock must be on a path the SANDBOX can write and that every probe
# sees: bubblewrap binds the gitf home read-only except a few subdirs, so
# /var/lib/gitf/probes/.lock failed to open (exit 127), and a per-sandbox
# /tmp would serialize nothing. ~/.cache is bound writable and shared.
LOCK_DIR="/var/lib/gitf/.cache"
mkdir -p "$LOCK_DIR" 2>/dev/null
exec 9>"$LOCK_DIR/gitf-probe.lock" || {
  say "TOOL MISSING on host: cannot open probe lock in $LOCK_DIR; this is an infrastructure problem, not a code problem"
  exit 127
}

# Short wait, then self-heal. A long wait was worse than useless: run 31
# blocked the FULL validation budget on a lock held by a corpse from a
# round killed before the killable-validation fix existed, producing exit
# 124 with no output at all. If the holder is dead, sweeping frees it; if
# it is a live sibling, the second wait lets it finish.
if ! flock -w 60 9; then
  say "probe lock busy after 60s — sweeping stale holders"
  pkill -f 'tauri-driver' 2>/dev/null
  pkill -f 'WebKitWebDriver' 2>/dev/null
  pkill -x cora 2>/dev/null
  pkill -f 'http\.server 1420' 2>/dev/null
  sleep 2
  if ! flock -w 120 9; then
    say "TOOL MISSING on host: probe lock still held after sweep; this is an infrastructure problem, not a code problem"
    exit 127
  fi
fi

# With the lock held, any surviving driver/server is a corpse from a round
# killed mid-flight (validator timeout = SIGKILL, traps never run), never a
# live sibling. Sweep it.
pkill -f 'tauri-driver' 2>/dev/null
pkill -f 'WebKitWebDriver' 2>/dev/null
pkill -x cora 2>/dev/null
pkill -f 'http\.server 1420' 2>/dev/null
sleep 1
if curl -s -m 2 -o /dev/null http://127.0.0.1:1420/; then
  say "FAIL: something still serves :1420 after cleanup — stale process outside this namespace"
  exit 1
fi

# Fresh driver ports per run — the devUrl port (1420) is baked into the
# binary, but the WebDriver ports need not collide across rounds.
DRIVER_PORT=$((20000 + RANDOM % 10000))
NATIVE_PORT=$((DRIVER_PORT + 1))
export WEBDRIVER_URL="http://127.0.0.1:$DRIVER_PORT"

# --- 0. disk floor ----------------------------------------------------------
# The build below transiently needs 1-2GB; running it onto a nearly-full
# disk is how the 2026-08-19 incident took the whole box down. Failing
# here with a TOOL-MISSING-style message keeps the validator classifying
# this as infrastructure, never as the ghost's code.
FREE_MB=$(df -Pk . | awk 'NR==2 {print int($4/1024)}')
if [ "${FREE_MB:-0}" -lt 1500 ]; then
  say "TOOL MISSING on host: only ${FREE_MB}MB disk free — probe build needs ~2GB; this is an infrastructure problem, not a code problem"
  exit 127
fi

# --- 1. frontend bundle (embedded into the binary at cargo build time) ------
say "building frontend bundle"
if ! npm run build >"$ART/vite-build.log" 2>&1; then
  tail -15 "$ART/vite-build.log"
  say "FAIL: vite build failed"
  exit 1
fi

# --- 2. the real binary ------------------------------------------------------
say "building app binary (shared cargo cache)"
if ! (cd src-tauri && cargo build -j 1 >"$ART/cargo-build.log" 2>&1); then
  tail -20 "$ART/cargo-build.log"
  say "FAIL: cargo build failed"
  exit 1
fi

BIN="$CARGO_TARGET_DIR/debug/cora"
if [ ! -x "$BIN" ]; then
  say "FAIL: built binary not found at $BIN"
  exit 1
fi

# --- 3. seeded app data: the legacy-settings fixture -------------------------
# A settings blob written BEFORE this mission's fields existed, with one
# watched repo so per-repo UI has a row to open. Exactly the shape every
# existing user's store has — the probe must exercise the app as an
# UPGRADE, not a fresh install.
# The app must be seeded at its REAL config dir: WebKitWebDriver launches
# the binary with a scrubbed environment, so XDG_* overrides never reach it
# (rounds 4-12 seeded dirs the app provably never opened — it kept
# recreating ~/.config/com.mp.cora regardless). This is a factory box and
# the dir is probe residue; recreate it fresh every run.
# HOME is redirected into the WORKTREE (bound writable by the sandbox for
# the whole run) rather than seeding ~/.config directly: bubblewrap binds
# the real ~/.config as it existed at sandbox start, so a dir the probe
# creates inside the sandbox lands on a read-only view and the app panics
# "attempt to write a readonly database" (orgs.rs) before first paint.
export HOME="$WT/.gitf-probe-home"
rm -rf "$HOME"
mkdir -p "$HOME"
APP_DIR="$HOME/.config/com.mp.cora"
DATA_ROOT="$HOME"
if [ "${KEEP_DATA:-0}" = "1" ]; then
  echo "$DATA_ROOT" > /tmp/cora-probe-last-data
  trap 'true' EXIT
else
  trap 'rm -rf "$DATA_ROOT"' EXIT
fi
# Seed the app's DEFAULT org (acceptance run 3 showed the app active on
# "team-and-tech" regardless of orgs.json) so whichever org-resolution
# path runs, the store it opens carries the fixture.
mkdir -p "$APP_DIR/orgs/team-and-tech"
cat >"$APP_DIR/orgs.json" <<'JSON'
{"active":"team-and-tech","enabled":["team-and-tech"]}
JSON
# The blob must carry EVERY field the Settings struct does not serde-default
# (pollIntervalSecs, githubGraphqlUrl, awsProfile, awsEndpointUrl,
# bedrockModelId as of 2026-08): settings() does unwrap_or_default, so a
# partial blob silently becomes fresh defaults and the fixture evaporates —
# acceptance rounds 4-8 chased that ghost.
sqlite3 "$APP_DIR/orgs/team-and-tech/cora.sqlite" <<'SQL'
CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT);
INSERT OR REPLACE INTO kv (key, value) VALUES
  ('settings', '{"watchedRepos":["octocat/hello-world"],"repoPriorities":{"octocat/hello-world":"high"},"pollIntervalSecs":300,"githubGraphqlUrl":"https://api.github.com/graphql","awsProfile":"probe","awsEndpointUrl":"","bedrockModelId":"probe-model"}');
SQL

# --- 3b. serve the built frontend on the devUrl port -------------------------
# A DEBUG tauri binary loads build.devUrl (localhost:1420) instead of the
# embedded dist — first acceptance run rendered "Connection refused" and
# the monkey false-passed on the empty page. Serving the real production
# bundle on that port keeps debug builds (fast, shared cache) honest.
say "serving dist/ on :1420"
(cd dist && python3 -m http.server 1420 >/dev/null 2>&1) &
HTTP_PID=$!

for _ in $(seq 1 15); do
  curl -s -m 2 -o /dev/null http://127.0.0.1:1420/ && break
  sleep 1
done
if ! curl -s -m 2 -o /dev/null http://127.0.0.1:1420/; then
  say "FAIL: static server for dist/ did not come up"
  kill "$HTTP_PID" 2>/dev/null
  exit 1
fi

# --- 4. driver under Xvfb ----------------------------------------------------
say "starting tauri-driver under Xvfb"
xvfb-run -a --server-args="-screen 0 1400x900x24" tauri-driver --port "$DRIVER_PORT" --native-port "$NATIVE_PORT" \
  >"$ART/tauri-driver.log" 2>&1 &
DRIVER_PID=$!
if [ "${KEEP_DATA:-0}" = "1" ]; then
  trap 'kill "$DRIVER_PID" "$HTTP_PID" 2>/dev/null' EXIT
else
  trap 'kill "$DRIVER_PID" "$HTTP_PID" 2>/dev/null; rm -rf "$DATA_ROOT"' EXIT
fi

for _ in $(seq 1 30); do
  curl -s -m 2 "$WEBDRIVER_URL/status" >/dev/null 2>&1 && break
  sleep 1
done
if ! curl -s -m 2 "$WEBDRIVER_URL/status" >/dev/null 2>&1; then
  tail -10 "$ART/tauri-driver.log"
  say "FAIL: tauri-driver did not come up"
  exit 1
fi

# --- 5. the monkey -----------------------------------------------------------
say "launching app + monkey probe"
timeout 300 node /var/lib/gitf/probes/monkey.mjs "$BIN" "$ART"
RC=$?

# A timeout usually means the app died before first paint (the monkey then
# polls a corpse until its deadline). The driver log carries the real
# reason — a Rust panic, a missing lib — so surface it in the verdict
# instead of leaving "exit 124" to be guessed at.
if [ "$RC" -eq 124 ]; then
  say "the app never reached first paint; last driver output:"
  grep -iE "panic|error|fatal|readonly|refused" "$ART/tauri-driver.log" 2>/dev/null | tail -5
fi

keep_artifacts

if [ "$RC" -eq 0 ]; then
  say "PASS: app booted and survived the click sweep (screenshots in .gitf-probe/)"
else
  say "FAIL (exit $RC): the app crashed at runtime — see the boundary stack above; screenshots in .gitf-probe/"
fi
exit "$RC"
