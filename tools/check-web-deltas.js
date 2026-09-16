#!/usr/bin/env node
//
// ChatBots — checks for the merge that turns the engine's per-token events into live text.
//
// The page used to listen only for whole-turn snapshots, so a reply appeared in one piece when the
// turn ended and a long research turn looked frozen while it was working. It now merges the `delta`
// events into `state.snapshot.live`, which is what the renderer draws from. That merge is pure and
// lives in `web/deltas.js` so it can be run here, in Node, without a browser.
//
//   usage: node tools/check-web-deltas.js
//
// Exit status: 0 when every case holds, 1 with the failing cases named.

"use strict";

const fs = require("fs");
const path = require("path");
const { applyDelta, emptyLive, isStale } = require(path.join(__dirname, "..", "web", "deltas.js"));

// The page is split across ES modules, so the source checks read every one of them: a case
// cannot pass because the code moved into a file this check did not know about. `deltas.js` and
// `votes.js` are excluded because they are the shared pure rules, not the page itself. The paths
// are literal on purpose — a name taken from a directory listing is what a path-traversal rule
// flags — so a new page module has to be added here as well as to `web/index.html`.
const appJS = [
  fs.readFileSync(path.join(__dirname, "..", "web", "app.js"), "utf8"),
  fs.readFileSync(path.join(__dirname, "..", "web", "app-core.js"), "utf8"),
  fs.readFileSync(path.join(__dirname, "..", "web", "app-screen.js"), "utf8"),
  fs.readFileSync(path.join(__dirname, "..", "web", "app-transcript.js"), "utf8"),
  fs.readFileSync(path.join(__dirname, "..", "web", "app-controls.js"), "utf8"),
  fs.readFileSync(path.join(__dirname, "..", "web", "app-lineup.js"), "utf8"),
  fs.readFileSync(path.join(__dirname, "..", "web", "app-commands.js"), "utf8"),
].join("\n");

let failures = 0;

function check(name, condition, detail) {
  if (condition) {
    console.log(`  ok    ${name}`);
  } else {
    failures += 1;
    console.log(`  FAIL  ${name}${detail ? ` — ${detail}` : ""}`);
  }
}

/** A snapshot with two seats and nothing being written yet. */
function snapshot() {
  return {
    seats: [{ id: "Agent 1" }, { id: "Agent 2" }],
    live: [
      { seatID: "Agent 1", isGenerating: false, text: "", reasoning: "", activity: null, toolLog: [], stats: null },
      { seatID: "Agent 2", isGenerating: false, text: "", reasoning: "", activity: null, toolLog: [], stats: null },
    ],
  };
}

const liveOf = (snap, id) => snap.live.find((entry) => entry.seatID === id);

console.log("web/deltas.js");

{
  const snap = snapshot();
  applyDelta(snap, { agentID: "Agent 1", kind: "token", text: "Hel" });
  applyDelta(snap, { agentID: "Agent 1", kind: "token", text: "lo" });
  check("token fragments accumulate in order", liveOf(snap, "Agent 1").text === "Hello",
    `got ${JSON.stringify(liveOf(snap, "Agent 1").text)}`);
  check("a seat that is writing is marked as generating", liveOf(snap, "Agent 1").isGenerating === true);
  check("the other seat is untouched", liveOf(snap, "Agent 2").text === "");
}

{
  const snap = snapshot();
  applyDelta(snap, { agentID: "Agent 1", kind: "reasoning", text: "why " });
  applyDelta(snap, { agentID: "Agent 1", kind: "token", text: "answer" });
  applyDelta(snap, { agentID: "Agent 1", kind: "reasoning", text: "not" });
  check("reasoning accumulates separately from the answer",
    liveOf(snap, "Agent 1").reasoning === "why not" && liveOf(snap, "Agent 1").text === "answer",
    `reasoning=${JSON.stringify(liveOf(snap, "Agent 1").reasoning)} text=${JSON.stringify(liveOf(snap, "Agent 1").text)}`);
}

{
  const snap = snapshot();
  applyDelta(snap, { agentID: "Agent 1", kind: "token", text: "from the last turn" });
  applyDelta(snap, { agentID: "Agent 1", kind: "reasoning", text: "old thinking" });
  applyDelta(snap, { agentID: "Agent 1", kind: "started", text: "" });
  check("a new turn clears what the previous one left",
    liveOf(snap, "Agent 1").text === "" && liveOf(snap, "Agent 1").reasoning === "",
    `text=${JSON.stringify(liveOf(snap, "Agent 1").text)}`);
  applyDelta(snap, { agentID: "Agent 1", kind: "token", text: "new" });
  check("and the new turn then accumulates from empty", liveOf(snap, "Agent 1").text === "new");
}

{
  const snap = snapshot();
  const changed = applyDelta(snap, { agentID: "Agent 9", kind: "token", text: "ghost" });
  check("an agent that is not a seat is ignored", changed === false && snap.live.length === 2);
  const unknown = applyDelta(snap, { agentID: "Agent 1", kind: "something-new", text: "x" });
  check("an unknown kind is ignored rather than guessed at", unknown === false,
    "the snapshot that follows the turn carries it");
  check("an empty delta is ignored", applyDelta(snap, null) === false && applyDelta(snap, { kind: "token" }) === false);
}

{
  const snap = snapshot();
  snap.live = [];
  applyDelta(snap, { agentID: "Agent 2", kind: "token", text: "a" });
  const entry = liveOf(snap, "Agent 2");
  check("a seat with no live entry gets one the renderer can read",
    entry && emptyLive("Agent 2").toolLog.length === 0 && Array.isArray(entry.toolLog) && entry.stats === null,
    JSON.stringify(entry));
}

{
  const snap = snapshot();
  snap.live = undefined;
  const changed = applyDelta(snap, { agentID: "Agent 1", kind: "token", text: "x" });
  check("a snapshot with no live array is repaired rather than throwing",
    changed === true && Array.isArray(snap.live) && liveOf(snap, "Agent 1").text === "x");
}

{
  const snap = snapshot();
  applyDelta(snap, { agentID: "Agent 1", kind: "token", text: "" });
  check("an empty fragment leaves the text a string", typeof liveOf(snap, "Agent 1").text === "string");
}

// ── which of two snapshots is newer ────────────────────────────────────────────────────────────────
//
// The page applied whatever arrived last, so the `GET /api/state` at load could race the first pushed
// snapshot and leave the older one on screen until the next turn. The app-side client has refused
// stale snapshots since that guard was added; this is the same rule, and the same fallback when a snapshot carries no
// revision.

{
  const older = { revision: 4, serverTime: "2026-09-15T10:00:00Z" };
  const newer = { revision: 5, serverTime: "2026-09-15T10:00:00Z" };

  check("a snapshot with a lower revision is stale", isStale(older, newer) === true);
  check("a snapshot with a higher revision is not", isStale(newer, older) === false);
  check("the same revision is not stale", isStale(newer, { ...newer }) === false);
  check("nothing to compare against is never stale", isStale(older, null) === false);

  // Same second, which is what the revision exists for: the clock cannot order these two.
  const sameSecondOlder = { revision: 7, serverTime: "2026-09-15T10:00:00Z" };
  const sameSecondNewer = { revision: 8, serverTime: "2026-09-15T10:00:00Z" };
  check(
    "the revision orders two snapshots inside the same second",
    isStale(sameSecondOlder, sameSecondNewer) === true &&
      isStale(sameSecondNewer, sameSecondOlder) === false);

  // An older engine sends no revision, so the clock is the only ordering there is.
  const clockOlder = { serverTime: "2026-09-15T09:59:59Z" };
  const clockNewer = { serverTime: "2026-09-15T10:00:00Z" };
  check("without a revision the clock decides", isStale(clockOlder, clockNewer) === true);
  check("and it does not call a later clock stale", isStale(clockNewer, clockOlder) === false);
  check(
    "a revision on one side only falls back to the clock",
    isStale(clockOlder, { revision: 3, serverTime: "2026-09-15T10:00:00Z" }) === true);

  // The revision decides even when there is no clock to fall back to.
  check(
    "a revision orders without any serverTime",
    isStale({ revision: 1 }, { revision: 2 }) === true);

  // Neither orders: refuse rather than guess, so a malformed snapshot cannot blank the page.
  check("an unorderable pair is not treated as stale", isStale({}, {}) === false);
}

// ── and the page actually uses it ─────────────────────────────────────────────────────────────────
//
// The defect was not a missing rule — `APISnapshot.isOlder(than:)` has existed since that guard was added and the app
// uses it — but a page that applied whatever arrived last. A rule nothing calls is the thing this
// file's tests would otherwise pass on, so the call is checked too.

{
  check(
    "every snapshot the page applies goes through the guard",
    /isStale\(next, state\.snapshot\)/.test(appJS));

  // The stylesheet documents the profile badge as "shown only when ?profile is in the URL", and
  // nothing implemented the condition — the text went into an element the stylesheet keeps hidden. The
  // browser behaviour is not exercised here (there is no headless browser in this check); what is
  // checked is that the page both reads `?profile` and applies it to the badge.
  check("the debug label reads ?profile", /has\("profile"\)/.test(appJS));
  check("and the badge is shown only when it is asked for", /badge\.hidden = !profileRequested\(\)/.test(appJS));

  // The page disables removing an attachment on `canAttach`, which turned out to be *right* —
  // `ConversationEngine.setAttachments` refuses once `turnsCompleted > 0`, so the engine's rule is the
  // page's. What was wrong was the other two sides: `EngineService` discarded that refusal and
  // reported success, and the Mac app's ✕ was `.disabled(false)`. The case below pins the page's side
  // of the agreement so a future edit cannot quietly disagree again.
  check(
    "the page gates removing an attachment on the same flag the engine uses",
    /remove\.disabled = !state\.snapshot\.canAttach/.test(appJS));

  // The moderator's draft was emptied *before* the send, so a message the engine refused — or one
  // that never left the page because the engine could not be reached — silently discarded what had been
  // typed. The browser interaction is not exercised here; what is checked is the ordering that was
  // wrong, that the helper the ordering depends on reports the outcome, and that the guard which used to
  // be the emptied box is now explicit.
  const sendBody = appJS.slice(
    appJS.indexOf("async function send()"),
    appJS.indexOf("function autosize(box)"));
  const runBody = appJS.slice(
    appJS.indexOf("async function run(fn)"),
    appJS.indexOf("── Kept conversations"));
  check("the command helper reports whether the engine took the command",
    /return true;/.test(runBody) && /return false;/.test(runBody));
  check("the page posts the message before it empties the box",
    sendBody.indexOf('api.post("/api/message"') < sendBody.indexOf('box.value = ""'));
  check("and it empties the box only when the send was accepted",
    /if \(!\(await run\(\(\) => api\.post\("\/api\/message", \{ text \}\)\)\)\) return;/.test(sendBody));
  check("so that what is typed during the request is not thrown away",
    /box\.value\.trim\(\) === text/.test(sendBody));
  check("and a second Return cannot post the same text twice",
    /if \(!text \|\| sending\) return;/.test(sendBody));

  // The checkpoint picker. The page offers the list the engine sends rather than a copy of the
  // catalogue, posts the change to the same seat route the app uses, and locks the control on the same
  // flag the engine refuses on.
  check("the page fills the model picker from the engine's catalogue",
    /const models = s\.availableModels \|\| \[\];/.test(appJS) && /modelPicker\.append\(option\)/.test(appJS));
  check("the page posts the chosen checkpoint to the seat route",
    /api\.post\("\/api\/seat", \{ seat: seat\.id, modelID: modelPicker\.value \}\)/.test(appJS));
  check("and locks it on the same flag the engine refuses on",
    /modelPicker\.disabled = !s\.canAttach;/.test(appJS));
}

if (failures === 0) {
  console.log("all deltas checks passed");
  process.exit(0);
}
console.log(`${failures} deltas check(s) failed`);
process.exit(1);
