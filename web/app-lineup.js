// ChatBots — the line-up panel: who is in the room, and what they are put in front of.
//
// The libraries come from the engine rather than being compiled in here, so a line-up added on
// the other side appears in this panel without the page being rebuilt. It is its own module
// because the panel is the one part of the page that is entirely about the engine's own lists.

import { $, api, state, toast } from "./app-core.js";
import { run } from "./app-commands.js";

export function currentMode() {
  return state.snapshot && state.snapshot.mode === "research" ? "research" : "entertainment";
}

function lineupRow(entry) {
  const row = document.createElement("div");
  row.className = "lineup-row";

  const text = document.createElement("div");
  text.className = "lineup-text";
  const name = document.createElement("div");
  name.className = "lineup-name";
  name.textContent = entry.title;
  const note = document.createElement("div");
  note.className = "lineup-note";
  note.textContent = entry.note;
  text.append(name, note);
  if (entry.who) {
    const who = document.createElement("div");
    who.className = "lineup-who";
    who.textContent = entry.who;
    text.append(who);
  }

  const apply = document.createElement("button");
  apply.className = "small";
  apply.textContent = "Apply";
  apply.disabled = Boolean(state.snapshot && state.snapshot.isRunning);
  if (apply.disabled) apply.title = "Stop the conversation first";
  apply.onclick = () => run(() => api.post(entry.path, entry.body));

  row.append(text, apply);
  return row;
}

export async function refreshLineup() {
  const body = $("lineup-body");
  body.textContent = "";
  const mode = currentMode();
  $("lineup-meta").textContent = mode === "research" ? "research" : "show";

  // The libraries come from the engine rather than being compiled in here, so a line-up
  // added on the other side appears in this panel without the page being rebuilt.
  let rosters = [];
  let scenarios = [];
  try {
    [rosters, scenarios] = await Promise.all([
      api.get(`/api/rosters?mode=${mode}`),
      api.get(`/api/scenarios?mode=${mode}`),
    ]);
  } catch (error) {
    toast(error.message);
    return;
  }

  const heading = (label) => {
    const el = document.createElement("div");
    el.className = "lineup-section";
    el.textContent = label;
    return el;
  };

  body.append(heading("Line-ups"));
  const random = lineupRow({
    title: "Surprise me — a random room",
    note: "Drawn from every participant in this mode. The seed is reported in the log, so the draw can be repeated.",
    who: "",
    path: "/api/roster",
    body: { id: "random" },
  });
  body.append(random);
  for (const roster of rosters) {
    body.append(lineupRow({
      title: roster.name,
      note: roster.summary,
      who: roster.personaIDs.join(" · "),
      path: "/api/roster",
      body: { id: roster.id },
    }));
  }

  body.append(heading("Scenarios"));
  for (const scenario of scenarios) {
    body.append(lineupRow({
      title: scenario.topic,
      note: scenario.note,
      who: scenario.depth ? `budget: ${scenario.depth}` : "",
      path: "/api/scenario",
      body: { id: scenario.id },
    }));
  }
}
