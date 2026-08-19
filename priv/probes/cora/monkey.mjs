#!/usr/bin/env node
// Bounded monkey probe for a Tauri app driven through tauri-driver (W3C
// WebDriver). No dependencies — raw fetch against the driver.
//
// Contract: exit 0 when the app boots and survives clicking every reachable
// control without tripping the app's error boundary; exit 3 the moment the
// boundary's marker text renders, printing the boundary's stack. The factory
// treats a nonzero exit as validation ground truth.
//
// Usage: node monkey.mjs <app-binary> <artifact-dir>
//   env: WEBDRIVER_URL (default http://127.0.0.1:4444)
//        MONKEY_MAX_CLICKS (default 40), MONKEY_MAX_MS (default 120000)

const [, , APP, ARTIFACTS] = process.argv;
const BASE = process.env.WEBDRIVER_URL || "http://127.0.0.1:4444";
const MAX_CLICKS = Number(process.env.MONKEY_MAX_CLICKS || 40);
const MAX_MS = Number(process.env.MONKEY_MAX_MS || 120_000);
const OVERLAY_MARKER = "hit a rendering error";

if (!APP) {
  console.error("usage: monkey.mjs <app-binary> [artifact-dir]");
  process.exit(2);
}

const fs = await import("node:fs");
if (ARTIFACTS) fs.mkdirSync(ARTIFACTS, { recursive: true });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function wd(method, path, body) {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(`webdriver ${method} ${path} -> ${res.status}: ${JSON.stringify(json).slice(0, 300)}`);
  }
  return json.value;
}

let sessionId = null;
const S = (p) => `/session/${sessionId}${p}`;

async function execScript(script, args = []) {
  return wd("POST", S("/execute/sync"), { script, args });
}

async function execAsync(script, args = []) {
  return wd("POST", S("/execute/async"), { script, args });
}

// Seed fixture state through the app's OWN IPC — the only channel that is
// guaranteed to hit whatever store the running app actually uses.
// Filesystem/env seeding lost every round: WebKitWebDriver launches the
// binary with a scrubbed environment and the data dir raced the probe's
// assumptions. get_settings → patch → set_settings sidesteps all of it.
async function seedViaIpc(repo) {
  const result = await execAsync(
    `const cb = arguments[arguments.length - 1];
     const repo = arguments[0];
     const inv = window.__TAURI_INTERNALS__ && window.__TAURI_INTERNALS__.invoke;
     if (!inv) { cb({ err: "no __TAURI_INTERNALS__.invoke" }); return; }
     inv("get_settings")
       .then((s) => {
         s.watchedRepos = Array.from(new Set([...(s.watchedRepos || []), repo]));
         s.repoPriorities = { ...(s.repoPriorities || {}), [repo]: "high" };
         return inv("set_settings", { settings: s }).then(() => inv("get_settings"));
       })
       .then((s) => cb({ ok: (s.watchedRepos || []).includes(repo) }))
       .catch((e) => cb({ err: String(e) }));`,
    [repo]
  ).catch((e) => ({ err: String(e) }));

  if (result && result.ok) {
    console.log(`fixture seeded via IPC: ${repo} watched`);
    return true;
  }
  console.error(`PROBE FAIL: could not seed fixture via IPC (${result && result.err})`);
  return false;
}

async function screenshot(name) {
  if (!ARTIFACTS) return;
  try {
    const b64 = await wd("GET", S("/screenshot"));
    fs.writeFileSync(`${ARTIFACTS}/${name}.png`, Buffer.from(b64, "base64"));
  } catch {
    /* screenshots are best-effort evidence, never the verdict */
  }
}

// The verdict check: is the error boundary showing anywhere in this window?
async function overlayStack() {
  return execScript(
    `const m = document.body ? document.body.innerText : "";
     if (!m.toLowerCase().includes(${JSON.stringify(OVERLAY_MARKER)})) return null;
     const pre = document.querySelector("pre");
     return (pre && pre.innerText) || m.slice(0, 2000);`
  );
}

async function failIfOverlay(context) {
  const stack = await overlayStack();
  if (stack != null) {
    await screenshot("FAIL-overlay");
    console.error(`PROBE FAIL: app error boundary rendered (${context})`);
    console.error("--- boundary stack ---");
    console.error(String(stack).slice(0, 1500));
    await teardown();
    process.exit(3);
  }
}

// Clickable controls, keyed by stable-ish identity so each is clicked once.
async function listClickables() {
  return execScript(
    `const sel = 'button, [role="button"], select, summary, .action-btn, .icon-btn';
     const out = [];
     document.querySelectorAll(sel).forEach((el, i) => {
       const r = el.getBoundingClientRect();
       if (r.width < 2 || r.height < 2) return;                 // invisible
       const style = getComputedStyle(el);
       if (style.visibility === "hidden" || style.display === "none") return;
       const key = (el.getAttribute("aria-label") || el.getAttribute("data-tip") ||
                    el.innerText || el.className || el.tagName).trim().slice(0, 60) + "#" + el.tagName;
       out.push({ i, key });
     });
     return out;`
  );
}

async function clickIndex(i) {
  return execScript(
    `const sel = 'button, [role="button"], select, summary, .action-btn, .icon-btn';
     const el = document.querySelectorAll(sel)[arguments[0]];
     if (el) el.click();
     return !!el;`,
    [i]
  );
}

async function teardown() {
  try {
    await wd("DELETE", `/session/${sessionId}`);
  } catch {
    /* the driver kills the app with the session; nothing else to do */
  }
}

// ---- run --------------------------------------------------------------------

const session = await wd("POST", "/session", {
  capabilities: { alwaysMatch: { "tauri:options": { application: APP } } },
});
sessionId = session.sessionId;
console.log(`session ${sessionId} for ${APP}`);

// Wait for a real UI, not just a document: the first acceptance run
// false-passed on a "Connection refused" placeholder page with zero
// controls. An app screen with NOTHING clickable is a failure in itself.
let booted = false;
for (let waited = 0; waited < 30_000; waited += 1000) {
  await failIfOverlay("initial render");
  const targets = await listClickables().catch(() => []);
  if ((targets || []).length > 0) {
    booted = true;
    break;
  }
  await sleep(1000);
}
await screenshot("boot");

// The click sweep only proves surfaces it can reach; per-repo UI needs a
// repo to exist. Seed one through IPC before sweeping — a failure to seed
// is a probe-infrastructure failure, not a pass.
if (booted && !(await seedViaIpc(process.env.MONKEY_GREP || "octocat/hello-world"))) {
  await teardown();
  process.exit(5);
}

if (!booted) {
  const text = await execScript(`return document.body ? document.body.innerText.slice(0, 400) : "(no body)"`).catch(() => "(unreadable)");
  console.error("PROBE FAIL: no interactive controls appeared within 30s — the UI did not boot");
  console.error(`page text: ${text}`);
  await teardown();
  process.exit(4);
}

const clicked = new Set();
const deadline = Date.now() + MAX_MS;
let clicks = 0;
let prevKeys = new Set();
// Discovery order per key: the sweep explores newest-revealed UI first
// (true DFS). Round 14: Configure… and "Unwatch and clear priority" were
// revealed together, DOM-order picked Unwatch, and the fixture row was
// deleted before Configure… was ever clicked.
const discovery = new Map();
let scanCount = 0;

while (clicks < MAX_CLICKS && Date.now() < deadline) {
  let targets;
  try {
    targets = await listClickables();
  } catch (e) {
    // A click may legitimately close the window/app; that is a pass for
    // this surface, not a crash.
    console.log(`window went away after ${clicks} clicks (${String(e).slice(0, 120)})`);
    break;
  }

  targets = targets || [];

  // Depth-first: a control that APPEARED because of the last click (a
  // freshly opened pane, drawer, dialog) is explored before older
  // siblings — breadth-first by DOM order sailed past the Repositories
  // pane's Configure… button, the exact control hiding PR #6's crash.
  // Closers (Close/Done/Dismiss) come dead last within each tier, or a
  // freshly opened surface gets shut before its content is ever touched.
  const isCloser = (t) => /close|done|dismiss|cancel|back|✕|✖/i.test(t.key);
  // Destructive controls (round 14: "Unwatch and clear priority" deleted
  // the fixture row before its sibling Configure… was ever clicked).
  const isDestructive = (t) => /unwatch|untrack|delete|remove|clear|reset/i.test(t.key);
  const unclicked = targets.filter((t) => !clicked.has(t.key));
  const freshOnes = unclicked.filter((t) => !prevKeys.has(t.key));

  scanCount += 1;
  for (const t of targets) {
    if (!discovery.has(t.key)) discovery.set(t.key, scanCount);
  }

  if (freshOnes.length > 0) {
    console.log(`  saw: ${freshOnes.map((t) => t.key.replace(/\n/g, " ")).join(" | ").slice(0, 300)}`);
  }

  // True DFS: newest-discovered batch first (stable within a batch = DOM
  // order), constructive before destructive before closers. Reverse-DOM
  // alone still let sibling-batch destructive controls run first.
  const newestFirst = (list) =>
    list.slice().sort((a, b) => (discovery.get(b.key) || 0) - (discovery.get(a.key) || 0))[0];

  const next =
    newestFirst(unclicked.filter((t) => !isCloser(t) && !isDestructive(t))) ||
    newestFirst(unclicked.filter((t) => isDestructive(t) && !isCloser(t))) ||
    newestFirst(unclicked);
  prevKeys = new Set(targets.map((t) => t.key));
  if (!next) break; // every reachable control exercised

  clicked.add(next.key);
  clicks += 1;
  console.log(`click ${clicks}: ${next.key}`);

  try {
    await clickIndex(next.i);
  } catch {
    continue; // stale index after a re-render — rescan next loop
  }

  await sleep(400);
  if (process.env.MONKEY_VERBOSE === "1") {
    const info = await execScript(
      `const t = document.body ? document.body.innerText.replace(/\\n+/g, " · ") : "";
       const probe = ${JSON.stringify(process.env.MONKEY_GREP || "octocat")};
       const i = t.indexOf(arguments[0] || "Watch all PRs");
       return {
         fixture: t.includes(probe),
         around: i >= 0 ? t.slice(Math.max(0, i - 60), i + 260) : t.slice(-240),
       };`,
      ["Watch all PRs"]
    ).catch(() => ({ fixture: false, around: "(unreadable)" }));
    console.log(`  fixture:${info.fixture ? "VISIBLE" : "absent"} | ${info.around}`);
  }
  await failIfOverlay(`after clicking "${next.key}"`);
}

await screenshot("final");
await teardown();
console.log(`PROBE PASS: ${clicks} clicks, no error boundary`);
process.exit(0);
