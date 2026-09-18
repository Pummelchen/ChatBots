// ChatBots — the transcript: the panes, the single-column thread, and one message row.
//
// A turn is drawn once and left alone, so rendered elements are kept in maps keyed by id and the
// transcript is rebuilt only when the shape of the DOM changes. The reply being written is the
// exception — it is updated in place, and it lives in `app.js` with the other live drawing.

import {
  $,
  api,
  state,
  containers,
  panes,
  seatIndexOf,
  formatTime,
  bodyHTML,
  labelFor,
  voteFor,
  toast,
} from "./app-core.js";
import { run } from "./app-commands.js";

/** Rendered messages, keyed by id, so a turn is drawn once per container. */
const rendered = new Map();
const threadCopy = new Map();

/**
 * Mark the verdicts on the messages already drawn.
 *
 * A vote changes only the two buttons inside one message, and a turn is drawn once — so
 * rebuilding the transcript to show it would throw away the scroll position and any output
 * still arriving. The buttons are updated where they are instead.
 */
export function drawVotes() {
  for (const el of document.querySelectorAll(".msg[data-id]")) {
    const cast = voteFor(el.dataset.id);
    for (const button of el.querySelectorAll(".vote")) {
      // The verdict is read from the button rather than from its label, and the comparison is the
      // same one the click handler makes.
      if (window.ChatBotsVotes.isOn(cast, button.dataset.verdict)) button.dataset.on = "1";
      else delete button.dataset.on;
    }
  }
}

function messageElement(message) {
  const seat = seatIndexOf(message);
  const el = document.createElement("div");
  el.className = "msg";
  el.dataset.id = message.id;
  el.dataset.kind = message.kind;
  if (seat >= 0) el.dataset.seat = String(seat);

  const head = document.createElement("div");
  head.className = "msg-head";
  const who = document.createElement("span");
  who.className = "msg-who";
  who.textContent = labelFor(message);
  const time = document.createElement("span");
  time.className = "msg-time";
  time.textContent = formatTime(message.timestamp);
  head.append(who, time);

  const body = document.createElement("div");
  body.className = "msg-body";
  body.innerHTML = bodyHTML(message.text || "");

  el.append(head, body);
  // Only a contribution can be scored. A vote on the topic or on the moderator's own
  // assignment would be a judgement of something nobody argued.
  if (message.kind === "chat") el.append(voteRow(message));
  return el;
}

/** The audience's verdict on one contribution. */
function voteRow(message) {
  const row = document.createElement("div");
  row.className = "vote-row";
  const cast = voteFor(message.id);
  for (const [verdict, title] of [
    ["strong", "Moved it forward"],
    ["weak", "Did not hold up"],
  ]) {
    const button = document.createElement("button");
    button.className = "vote";
    button.textContent = verdict === "strong" ? "▲" : "▼";
    button.title = title;
    button.setAttribute("aria-label", title);
    button.dataset.verdict = verdict;
    if (window.ChatBotsVotes.isOn(cast, verdict)) button.dataset.on = "1";
    button.onclick = () => {
      // Clicking the verdict already cast withdraws it, so a mis-click does not have to be
      // reversed by casting its opposite — which would leave a wrong judgement in the record.
      //
      // The verdict on record is read *now*, not taken from the `cast` this row was built with: a
      // turn is drawn once and its marks are redrawn in place, so a captured value is the one from
      // the moment the row appeared — normally none — and clicking the cast verdict re-cast it
      // instead of withdrawing it.
      const next = window.ChatBotsVotes.nextVerdict(voteFor(message.id), verdict);
      run(() => api.post("/api/vote", { id: message.id, verdict: next }));
    };
    row.append(button);
  }
  return row;
}

/**
 * Build one pane per seat.
 *
 * The seat count is 2, 3 or 4, so the panes cannot be in the markup — the original version
 * hard-coded two, which is what made a four-seat room impossible in the web interface even
 * though the engine supported it.
 *
 * Rebuilding clears the rendered messages, because every pane's transcript is replaced; the
 * caller redraws afterwards.
 */
export function buildPanes(seatCount) {
  const stage = $("stage");
  const build = document.body.dataset.seats;
  if (build === String(seatCount)) return false;
  document.body.dataset.seats = String(seatCount);

  // Remove existing panes but leave the thread container.
  for (const pane of stage.querySelectorAll(".pane")) pane.remove();

  const template = $("pane-template");
  const thread = $("thread");
  for (let index = 0; index < seatCount; index += 1) {
    const pane = template.content.firstElementChild.cloneNode(true);
    pane.dataset.seat = String(index);
    pane.querySelector(".name").dataset.rename = String(index);
    pane.querySelector(".dot").textContent = String.fromCharCode(65 + index);
    stage.insertBefore(pane, thread);
  }
  wirePaneControls();
  rebuildTranscripts();
  return true;
}

/** Renaming is per pane, so it has to be attached whenever the panes are rebuilt. */
export function wirePaneControls() {
  for (const button of document.querySelectorAll(".name")) {
    // Guard against attaching twice to a pane that survived.
    if (button.dataset.wired === "1") continue;
    button.dataset.wired = "1";
    button.addEventListener("dblclick", () => startRename(button));
    button.addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        startRename(button);
      }
    });
  }
}

function startRename(button) {
  // Already renaming, so this is a re-entry rather than a start. The pane's own Enter handler and
  // the one `finish` installs are both keydown listeners on this button, and the pane's runs
  // first; Enter therefore called this again and added another blur/keydown pair, so a later
  // Enter posted /api/seat once more for a name that had already been committed.
  if (button.isContentEditable) return;
  if (state.snapshot && !state.snapshot.canAttach) {
    toast("Names are fixed once the conversation has started.");
    return;
  }
  const index = Number(button.dataset.rename);
  const seat = state.snapshot.seats[index];
  button.contentEditable = "true";
  button.focus();
  const range = document.createRange();
  range.selectNodeContents(button);
  const selection = getSelection();
  selection.removeAllRanges();
  selection.addRange(range);

  const finish = async (commit) => {
    button.contentEditable = "false";
    const value = button.textContent.trim();
    button.removeEventListener("blur", onBlur);
    button.removeEventListener("keydown", onKey);
    if (!commit || !value || value === seat.name) {
      button.textContent = seat.name;
      return;
    }
    await run(() => api.post("/api/seat", { seat: seat.id, name: value }));
  };
  const onBlur = () => finish(true);
  const onKey = (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      finish(true);
    }
    if (event.key === "Escape") {
      event.preventDefault();
      finish(false);
    }
  };
  button.addEventListener("blur", onBlur);
  button.addEventListener("keydown", onKey);
}

/** Throw away the rendered copies, for when the shape of the DOM changes. */
export function rebuildTranscripts() {
  rendered.clear();
  threadCopy.clear();
  for (const container of containers()) container.textContent = "";
}

export function drawMessages() {
  if (!state.snapshot) return;
  const inThread = document.body.dataset.layout === "thread";

  for (const message of state.snapshot.messages) {
    const seat = seatIndexOf(message);
    const shared =
      message.kind === "steering" ||
      message.kind === "topic" ||
      message.kind === "summary" ||
      message.kind === "direction";

    // The single-column view holds everything once.
    if (inThread) {
      if (threadCopy.has(message.id)) continue;
      const el = messageElement(message);
      threadCopy.set(message.id, el);
      $("thread").append(el);
      continue;
    }

    // The two-pane view splits by speaker, with moderator turns in both.
    for (const [index, pane] of panes().entries()) {
      const belongs = seat === index || shared || (message.kind === "tool" && seat === index);
      if (!belongs) continue;
      const key = `${message.id}:${index}`;
      if (rendered.has(key)) continue;
      const el = messageElement(message);
      rendered.set(key, el);
      pane.transcript.append(el);
    }
  }
  trimEmptyNotes();
}

function trimEmptyNotes() {
  for (const container of containers()) {
    const has = container.querySelector(".msg");
    const note = container.querySelector(".empty");
    if (has && note) note.remove();
    if (!has && !note) {
      const empty = document.createElement("div");
      empty.className = "empty";
      empty.textContent =
        document.body.dataset.layout === "thread"
          ? "Nothing yet. Set a topic and press Start."
          : "Nothing yet.";
      container.append(empty);
    }
  }
}
