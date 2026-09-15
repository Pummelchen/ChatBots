#!/usr/bin/env node
//
// ChatBots — checks for the merge that turns the engine's per-token events into live text (A165).
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

const path = require("path");
const { applyDelta, emptyLive } = require(path.join(__dirname, "..", "web", "deltas.js"));

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

if (failures === 0) {
  console.log("all deltas checks passed");
  process.exit(0);
}
console.log(`${failures} deltas check(s) failed`);
process.exit(1);
