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

# A round killed mid-flight (validator timeout = SIGKILL, traps never run)
# leaks its driver and static server; the NEXT round's driver then dies on
# "address in use" while the monkey talks to the stale driver serving a
# dead worktree — blank page, false "UI did not boot". Sweep first; the
# network namespace is shared, so squatters from any round hold real ports.
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

# --- 1. frontend bundle (embedded into the binary at cargo build time) ------
say "building frontend bundle"
if ! npm run build >"$ART/vite-build.log" 2>&1; then
  tail -15 "$ART/vite-build.log"
  say "FAIL: vite build failed"
  exit 1
fi

# --- 2. the real binary ------------------------------------------------------
say "building app binary (shared cargo cache)"
if ! (cd src-tauri && cargo build -j 2 >"$ART/cargo-build.log" 2>&1); then
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
APP_DIR="$HOME/.config/com.mp.cora"
rm -rf "$APP_DIR"
DATA_ROOT="$APP_DIR"
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
export HOME="${HOME:-/var/lib/gitf}"

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

if [ "$RC" -eq 0 ]; then
  say "PASS: app booted and survived the click sweep (screenshots in .gitf-probe/)"
else
  say "FAIL (exit $RC): the app crashed at runtime — see the boundary stack above; screenshots in .gitf-probe/"
fi
exit "$RC"
