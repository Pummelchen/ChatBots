#!/usr/bin/env node
//
// ChatBots — checks for the audience's verdict rule.
//
// A turn is drawn once and its vote buttons are re-marked in place, so the row's click handler used to
// work from the verdict the row was built with — normally none. Clicking the verdict already cast then
// re-cast it instead of withdrawing it, even though the button was visibly on: the page contradicted
// both its own comment and the engine's contract, where a vote with `null` withdraws.
//
// The rule is pure and lives in `web/votes.js` so it can be run here, in Node, without a browser:
// `nextVerdict(current, clicked)` is what a click means and `isOn(current, verdict)` is whether a button
// is the one on record. The page's use of them is checked as source, because the failure was that the
// handler used a *captured* value — which no pure-function case can see.
//
//   usage: node tools/check-web-votes.js
//
// Exit status: 0 when every case holds, 1 with the failing cases named.

"use strict";

const fs = require("fs");
const path = require("path");
const { nextVerdict, isOn } = require(path.join(__dirname, "..", "web", "votes.js"));

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

// ── The decision ────────────────────────────────────────────────────────────────────

check(
  "clicking a verdict that is not on records it",
  nextVerdict(null, "strong") === "strong" && nextVerdict(null, "weak") === "weak"
);
check(
  "clicking the other verdict replaces it",
  nextVerdict("weak", "strong") === "strong" && nextVerdict("strong", "weak") === "weak"
);
check(
  "clicking the verdict already on withdraws it",
  nextVerdict("strong", "strong") === null && nextVerdict("weak", "weak") === null,
  "this is the finding: the click re-cast instead of withdrawing"
);

// ── The mark ────────────────────────────────────────────────────────────────────────

check(
  "the verdict on record is the one marked",
  isOn("strong", "strong") === true && isOn("weak", "weak") === true
);
check(
  "the other verdict is not marked",
  isOn("strong", "weak") === false && isOn("weak", "strong") === false
);
check(
  "nothing is marked when nothing is on record",
  isOn(null, "strong") === false && isOn(null, "weak") === false
);

// ── The page's use of the rule ──────────────────────────────────────────────────────

check(
  "the click handler reads the verdict on record at click time",
  /nextVerdict\(voteFor\(message\.id\), verdict\)/.test(appJS),
  "the handler must call nextVerdict with the current verdict, not with a captured one"
);
check(
  "the handler no longer decides from the value captured at render time",
  !/const next = cast === verdict/.test(appJS),
  "a captured verdict is the bug: the row is built once and re-marked in place"
);
check(
  "the row marks a button through the shared rule",
  /window\.ChatBotsVotes\.isOn\(cast, verdict\)/.test(appJS)
);
check(
  "the redraw marks a button through the same rule, from the button's own verdict",
  /isOn\(cast, button\.dataset\.verdict\)/.test(appJS) &&
    /button\.dataset\.verdict = verdict/.test(appJS)
);
check(
  "the chosen verdict is what is posted, withdrawal included",
  /api\.post\("\/api\/vote", \{ id: message\.id, verdict: next \}\)/.test(appJS)
);
check(
  "the module is loaded before the page that uses it",
  /<script src="\/votes\.js"><\/script>\s*<script type="module" src="\/app\.js"><\/script>/.test(
    fs.readFileSync(path.join(__dirname, "..", "web", "index.html"), "utf8")
  )
);

if (failures === 0) {
  console.log("all votes checks passed");
  process.exit(0);
}
console.log(`${failures} votes check(s) failed`);
process.exit(1);
