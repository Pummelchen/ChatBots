// ChatBotsCore — the web interface, embedded
//
// Generated from `web/` by `tools/embed-web.py`; edit the files there, not here. It is
// embedded rather than read from disk so the server works from anywhere — a release build
// lives in `.build/`, and looking for `web/` relative to the binary would be a source of
// "works on my machine". Caddy serves the same files from `web/` directly, so both paths
// lead to identical bytes.
//
// `web/` remains the single source: this file is generated, so the two cannot drift.

import Foundation

public enum WebAssets {

    public struct Asset: Sendable {
        public var contentType: String
        public var body: Data
    }

    /// Look up a path from a request, or nil when it is not an asset.
    public static func asset(for path: String) -> Asset? {
        switch path {
        case "/", "/index.html":
            return Asset(contentType: "text/html; charset=utf-8", body: Data(indexHTML.utf8))
        case "/style.css":
            return Asset(contentType: "text/css; charset=utf-8", body: Data(styleCSS.utf8))
        case "/app.js":
            return Asset(contentType: "application/javascript; charset=utf-8", body: Data(appJS.utf8))
        case "/favicon.ico":
            return nil
        default:
            return nil
        }
    }

    static let indexHTML = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>ChatBots</title>
<link rel="stylesheet" href="/style.css">
</head>
<body data-layout="split">

<header class="bar">
  <div class="topic-row">
    <label class="lab" for="topic">
      <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M2 3h12v8H6l-3 3v-3H2z"/></svg>
      Topic
    </label>
    <input id="topic" type="text" autocomplete="off" spellcheck="false"
           placeholder="What should the models discuss?">
    <div class="transport">
      <button id="start" class="primary">Start</button>
      <button id="pause" disabled>Pause</button>
      <button id="stop" disabled>Stop</button>
      <button id="save" disabled title="Download the conversation log">Save</button>
      <button id="clear" disabled>Clear</button>
    </div>
  </div>

  <div class="attach-row">
    <button id="attach" class="small">Add files</button>
    <input id="files" type="file" multiple hidden>
    <span id="vision-note" class="note" hidden></span>
    <div id="chips" class="chips"></div>
  </div>

  <div class="control-row">
    <span id="status" class="pill">Idle</span>
    <span id="counts" class="note"></span>
    <summary class="personas" id="persona-summary"></summary>
    <div class="spacer"></div>
    <label class="toggle" title="Stream the models' thinking into the panes">
      <input id="thinking" type="checkbox" checked> Show thinking
    </label>
    <div class="seg" role="group" aria-label="Layout">
      <button id="layout-split" class="on" title="Side by side">Split</button>
      <button id="layout-thread" title="One column, like a chat">Thread</button>
    </div>
  </div>
</header>

<main id="stage">
  <section class="pane" data-pane="0">
    <div class="pane-head">
      <span class="dot" data-seat="0">A</span>
      <div class="who">
        <button class="name" data-rename="0" title="Double-click, or press, to rename">Agent 1</button>
        <span class="meta" data-meta="0"></span>
      </div>
      <div class="spacer"></div>
      <span class="state" data-state="0">idle</span>
    </div>
    <div class="params" data-params="0"></div>
    <div class="transcript" data-transcript="0"></div>
  </section>

  <section class="pane" data-pane="1">
    <div class="pane-head">
      <span class="dot" data-seat="1">B</span>
      <div class="who">
        <button class="name" data-rename="1" title="Double-click, or press, to rename">Agent 2</button>
        <span class="meta" data-meta="1"></span>
      </div>
      <div class="spacer"></div>
      <span class="state" data-state="1">idle</span>
    </div>
    <div class="params" data-params="1"></div>
    <div class="transcript" data-transcript="1"></div>
  </section>

  <div id="thread" class="thread" hidden></div>
</main>

<footer class="bar footer">
  <textarea id="message" rows="1" placeholder="Message both participants as the moderator…"></textarea>
  <button id="send" class="primary" disabled>Send to both</button>
  <div class="spacer"></div>
  <button id="condense" disabled title="Summarise the older turns now">Condense</button>
  <span id="context" class="note mono">ctx —</span>
</footer>

<div id="toast" class="toast" hidden></div>

<script src="/app.js"></script>
</body>
</html>

"""

    static let styleCSS = """
/* ChatBots — the web interface
 *
 * Two requirements shape this: it must be usable from a phone to a large desktop display,
 * and it must not look like a web page pretending to be an app. So it fills the viewport,
 * scrolls only inside the transcripts, and sizes everything from one root scale that the
 * media queries adjust — the same idea as the text-size setting in the SwiftUI app.
 */

:root {
  --scale: 1;
  --bg: #101014;
  --bg-raised: #17171d;
  --bg-sunken: #0b0b0f;
  --line: #2a2a34;
  --text: #ececf1;
  --text-dim: #9a9aa8;
  --text-faint: #6b6b7a;
  --seat-a: #4aa3ff;
  --seat-b: #b07cff;
  --mod: #ffc44d;
  --danger: #ff6b6b;
  --radius: 10px;
  --pad: calc(12px * var(--scale));
  --font: calc(13.5px * var(--scale));
  --font-small: calc(11px * var(--scale));
  --font-tiny: calc(10px * var(--scale));
}

@media (prefers-color-scheme: light) {
  :root {
    --bg: #f4f4f7;
    --bg-raised: #ffffff;
    --bg-sunken: #e9e9ef;
    --line: #d5d5de;
    --text: #1c1c22;
    --text-dim: #5c5c6a;
    --text-faint: #8a8a98;
  }
}

/* Roomier text on a phone, more of it on a tablet, and a comfortable measure on a desktop.
   The transcripts are the point, so they get the space rather than the furniture. */
@media (min-width: 700px)  { :root { --scale: 1; } }
@media (min-width: 1100px) { :root { --scale: 1.05; } }
@media (min-width: 1700px) { :root { --scale: 1.15; } }
@media (max-width: 560px)  { :root { --scale: 0.95; } }
@media (max-height: 560px) { :root { --scale: 0.9; } }

* { box-sizing: border-box; }

html, body {
  height: 100%;
  margin: 0;
  overflow: hidden;
  background: var(--bg);
  color: var(--text);
  font: var(--font)/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
  -webkit-font-smoothing: antialiased;
}

body {
  display: flex;
  flex-direction: column;
}

/* ── Controls ─────────────────────────────────────────────────────────────────────── */

.bar {
  flex: 0 0 auto;
  display: flex;
  flex-direction: column;
  gap: calc(8px * var(--scale));
  padding: var(--pad);
  background: var(--bg-raised);
  border-bottom: 1px solid var(--line);
}

.footer {
  border-bottom: none;
  border-top: 1px solid var(--line);
  flex-direction: row;
  align-items: center;
  gap: calc(8px * var(--scale));
}

.topic-row, .attach-row, .control-row {
  display: flex;
  align-items: center;
  gap: calc(8px * var(--scale));
  flex-wrap: wrap;
}

.lab {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  color: var(--text-dim);
  font-size: var(--font-small);
  font-weight: 600;
  white-space: nowrap;
}

.lab svg { width: 14px; height: 14px; fill: currentColor; }

input[type="text"], textarea {
  font: inherit;
  color: var(--text);
  background: var(--bg-sunken);
  border: 1px solid var(--line);
  border-radius: 8px;
  padding: calc(6px * var(--scale)) calc(9px * var(--scale));
  min-width: 0;
}

#topic { flex: 1 1 220px; }

textarea {
  flex: 1 1 auto;
  resize: none;
  max-height: calc(96px * var(--scale));
}

input:focus-visible, textarea:focus-visible, button:focus-visible {
  outline: 2px solid var(--seat-a);
  outline-offset: 1px;
}

input:disabled, textarea:disabled { opacity: 0.65; }

button {
  font: inherit;
  font-size: var(--font-small);
  color: var(--text);
  background: var(--bg-sunken);
  border: 1px solid var(--line);
  border-radius: 8px;
  padding: calc(6px * var(--scale)) calc(10px * var(--scale));
  cursor: pointer;
  white-space: nowrap;
}

button:hover:not(:disabled) { background: var(--line); }
button:disabled { opacity: 0.45; cursor: default; }

button.primary {
  background: var(--seat-a);
  border-color: transparent;
  color: #06121f;
  font-weight: 600;
}

button.small { font-size: var(--font-tiny); }

.transport { display: flex; gap: calc(6px * var(--scale)); flex: 0 0 auto; }

.spacer { flex: 1 1 auto; }

.pill {
  font-size: var(--font-small);
  font-weight: 600;
  padding: calc(4px * var(--scale)) calc(9px * var(--scale));
  border-radius: 999px;
  background: var(--bg-sunken);
  border: 1px solid var(--line);
  white-space: nowrap;
}

.pill.running { background: color-mix(in srgb, var(--seat-a) 22%, transparent); border-color: var(--seat-a); }
.pill.paused  { background: color-mix(in srgb, var(--mod) 22%, transparent); border-color: var(--mod); }
.pill.failed  { background: color-mix(in srgb, var(--danger) 22%, transparent); border-color: var(--danger); }

.note { color: var(--text-faint); font-size: var(--font-tiny); }
.mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }

.toggle { display: inline-flex; align-items: center; gap: 6px; font-size: var(--font-small); color: var(--text-dim); white-space: nowrap; }

.seg { display: flex; border: 1px solid var(--line); border-radius: 8px; overflow: hidden; }
.seg button { border: none; border-radius: 0; background: transparent; }
.seg button.on { background: var(--seat-a); color: #06121f; font-weight: 600; }

.personas { color: var(--text-faint); font-size: var(--font-tiny); }

.chips { display: flex; gap: 6px; flex-wrap: wrap; min-width: 0; }

.chip {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  background: var(--bg-sunken);
  border: 1px solid var(--line);
  border-radius: 999px;
  padding: calc(3px * var(--scale)) calc(4px * var(--scale)) calc(3px * var(--scale)) calc(10px * var(--scale));
  font-size: var(--font-tiny);
  max-width: 100%;
}

.chip b { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 34ch; }
.chip span { color: var(--text-faint); white-space: nowrap; }
.chip button { border: none; background: transparent; padding: 0 4px; font-size: var(--font-small); line-height: 1; }

/* ── Panes ────────────────────────────────────────────────────────────────────────── */

#stage {
  flex: 1 1 auto;
  min-height: 0;
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 1px;
  background: var(--line);
}

body[data-layout="thread"] #stage { grid-template-columns: 1fr; }
body[data-layout="thread"] .pane { display: none; }
body[data-layout="thread"] #thread { display: block; }

/* One column when two cannot fit: side-by-side on a phone would give each pane about
   fifteen characters, which is not a conversation. */
@media (max-width: 780px) {
  #stage { grid-template-columns: 1fr; }
}

.pane {
  display: flex;
  flex-direction: column;
  min-width: 0;
  min-height: 0;
  background: var(--bg);
}

.pane-head {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  gap: calc(8px * var(--scale));
  padding: calc(9px * var(--scale)) var(--pad);
  border-bottom: 1px solid var(--line);
  background: var(--bg-raised);
}

.dot {
  flex: 0 0 auto;
  width: calc(24px * var(--scale));
  height: calc(24px * var(--scale));
  border-radius: 50%;
  display: grid;
  place-items: center;
  font-size: var(--font-tiny);
  font-weight: 700;
  color: #06121f;
  background: var(--seat-a);
}

.pane:nth-child(2) .dot { background: var(--seat-b); }

.who { min-width: 0; }

.name {
  display: block;
  background: none;
  border: none;
  padding: 0;
  font-size: calc(14px * var(--scale));
  font-weight: 600;
  color: var(--text);
  text-align: left;
  max-width: 100%;
  overflow: hidden;
  text-overflow: ellipsis;
}

.name[contenteditable="true"] {
  background: var(--bg-sunken);
  border: 1px solid var(--seat-a);
  border-radius: 6px;
  padding: 1px 5px;
  outline: none;
}

.meta { display: block; font-size: var(--font-tiny); color: var(--text-faint); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

.state { font-size: var(--font-tiny); color: var(--text-faint); white-space: nowrap; }
.state.live { color: var(--seat-a); }

.params {
  flex: 0 0 auto;
  padding: calc(5px * var(--scale)) var(--pad);
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: var(--font-tiny);
  color: var(--text-faint);
  border-bottom: 1px solid var(--line);
  overflow-x: auto;
  white-space: nowrap;
  scrollbar-width: none;
}

.params::-webkit-scrollbar { display: none; }

.transcript, .thread {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  overflow-x: hidden;
  padding: var(--pad);
  display: flex;
  flex-direction: column;
  gap: calc(10px * var(--scale));
  scroll-behavior: smooth;
}

/* ── Messages ─────────────────────────────────────────────────────────────────────── */

.msg {
  border-left: 3px solid var(--line);
  padding: calc(7px * var(--scale)) calc(10px * var(--scale));
  border-radius: 0 8px 8px 0;
  background: var(--bg-raised);
  animation: fade 0.18s ease-out;
}

@keyframes fade { from { opacity: 0; transform: translateY(3px); } to { opacity: 1; } }

.msg[data-kind="topic"], .msg[data-kind="steering"] { border-left-color: var(--mod); }
.msg[data-kind="summary"] { border-left-color: var(--text-faint); font-style: italic; }
.msg[data-kind="tool"] { border-left-color: var(--line); background: transparent; }
.msg[data-seat="0"] { border-left-color: var(--seat-a); }
.msg[data-seat="1"] { border-left-color: var(--seat-b); }

.msg-head {
  display: flex;
  align-items: baseline;
  gap: 8px;
  margin-bottom: 3px;
}

.msg-who { font-size: var(--font-small); font-weight: 700; letter-spacing: 0.02em; }
.msg[data-seat="0"] .msg-who { color: var(--seat-a); }
.msg[data-seat="1"] .msg-who { color: var(--seat-b); }
.msg[data-kind="topic"] .msg-who, .msg[data-kind="steering"] .msg-who { color: var(--mod); }
.msg-time { font-size: var(--font-tiny); color: var(--text-faint); font-family: ui-monospace, Menlo, monospace; }
.msg-body { white-space: pre-wrap; overflow-wrap: anywhere; }
.msg-body p { margin: 0 0 0.6em; }
.msg-body p:last-child { margin-bottom: 0; }
.msg-body code { font-family: ui-monospace, Menlo, monospace; font-size: 0.92em; background: var(--bg-sunken); padding: 0 4px; border-radius: 4px; }

.msg.live { opacity: 0.96; }
.msg .thinking {
  margin-top: 6px;
  padding: 6px 8px;
  border-radius: 6px;
  background: var(--bg-sunken);
  color: var(--text-dim);
  font-size: var(--font-small);
  white-space: pre-wrap;
  max-height: 40vh;
  overflow-y: auto;
}

.caret::after {
  content: "";
  display: inline-block;
  width: 2px;
  height: 1em;
  margin-left: 2px;
  background: currentColor;
  vertical-align: text-bottom;
  animation: blink 1s steps(2) infinite;
}

@keyframes blink { 50% { opacity: 0; } }

.empty { color: var(--text-faint); font-size: var(--font-small); text-align: center; padding: 2em 1em; }

.toast {
  position: fixed;
  left: 50%;
  bottom: calc(78px * var(--scale));
  transform: translateX(-50%);
  background: var(--bg-raised);
  border: 1px solid var(--line);
  border-left: 3px solid var(--danger);
  border-radius: 8px;
  padding: 9px 14px;
  font-size: var(--font-small);
  box-shadow: 0 8px 28px rgba(0,0,0,0.4);
  max-width: min(560px, 90vw);
  z-index: 20;
}

.toast.good { border-left-color: var(--seat-a); }

/* ── The thread view: both participants in one column, like a chat ─────────────────── */

.thread .msg { max-width: min(760px, 100%); }
.thread .msg[data-seat="1"] { align-self: flex-end; }

@media (prefers-reduced-motion: reduce) {
  .msg { animation: none; }
  .transcript, .thread { scroll-behavior: auto; }
  .caret::after { animation: none; }
}

"""

    static let appJS = """
// ChatBots — the web interface
//
// A thin client over the HTTP API. It holds no conversation state of its own beyond what it
// has been told: the server owns the conversation, so a reload, a second tab, or the SwiftUI
// app all see the same thing. Where this does keep a copy — the message list — it exists
// only to avoid re-drawing the whole transcript sixty times a second.
//
// Two habits matter for the live transcript: a reply that is still being written is nested
// under the element that holds it, so text can be appended without rebuilding the list; and
// a scroll is only forced when the reader is already at the bottom, so reading back through
// the history does not get yanked away.

(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const api = {
    async get(path) {
      const r = await fetch(path, { headers: { Accept: "application/json" } });
      if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || r.statusText);
      return r.json();
    },
    async post(path, body) {
      const r = await fetch(path, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body || {}),
      });
      const data = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(data.error || r.statusText);
      return data;
    },
  };

  // Rendered messages, keyed by id, so a turn is only ever drawn once.
  const rendered = new Map();
  let state = null;
  let layout = localStorage.getItem("chatbots.layout") || "split";
  let follow = true;

  // ── Rendering ───────────────────────────────────────────────────────────────────

  /** The seat index a message belongs to, so it is coloured and filtered correctly. */
  function seatIndexOf(message) {
    if (!state) return -1;
    return state.seats.findIndex((s) => s.id === message.speakerID || s.name === message.speaker);
  }

  function formatTime(iso) {
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return "";
    const pad = (n) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
           `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  }

  /** Escape first, then apply the little formatting worth having. */
  function bodyHTML(text) {
    const safe = text
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    return safe
      .split(/\\n{2,}/)
      .map((para) => `<p>${para.replace(/`([^`]+)`/g, "<code>$1</code>")}</p>`)
      .join("");
  }

  function messageElement(message) {
    const seat = seatIndexOf(message);
    const el = document.createElement("div");
    el.className = "msg";
    el.dataset.id = message.id;
    el.dataset.kind = message.kind;
    if (seat >= 0) el.dataset.seat = String(seat);

    const who = document.createElement("div");
    who.className = "msg-head";
    const name = document.createElement("span");
    name.className = "msg-who";
    name.textContent = labelFor(message, seat);
    const time = document.createElement("span");
    time.className = "msg-time";
    time.textContent = formatTime(message.timestamp);
    who.append(name, time);

    const body = document.createElement("div");
    body.className = "msg-body";
    body.innerHTML = bodyHTML(message.text || "");

    el.append(who, body);
    return el;
  }

  function labelFor(message, seat) {
    switch (message.kind) {
      case "topic": return "MODERATOR · TOPIC";
      case "steering": return "MODERATOR";
      case "summary": return "CONDENSED EARLIER DISCUSSION";
      case "tool": return "TOOL";
      default: return (message.speaker || (seat >= 0 ? state.seats[seat].name : "?")).toUpperCase();
    }
  }

  /** Append messages that have not been drawn yet, in order. */
  function drawMessages() {
    if (!state) return;
    for (const message of state.messages) {
      if (rendered.has(message.id)) continue;
      const el = messageElement(message);
      rendered.set(message.id, el);
      // Everything goes into the thread; each pane gets what belongs to it.
      $("thread").append(el.cloneNode(true));
      for (const [index, pane] of panes().entries()) {
        const seat = seatIndexOf(message);
        if (seat === index) pane.transcript.append(el);
        else if (message.kind === "topic" || message.kind === "summary") {
          pane.transcript.append(el.cloneNode(true));
        }
      }
      // The moderator's own words belong in both panes: they are addressed to both.
      if (message.kind === "steering") {
        for (const pane of panes()) pane.transcript.append(el.cloneNode(true));
      }
    }
    trimEmptyNotes();
  }

  function panes() {
    return [...document.querySelectorAll(".pane")].map((el) => ({
      root: el,
      transcript: el.querySelector(".transcript"),
    }));
  }

  function trimEmptyNotes() {
    for (const pane of panes()) {
      const note = pane.transcript.querySelector(".empty");
      const hasMessages = pane.transcript.querySelector(".msg");
      if (hasMessages && note) note.remove();
      if (!hasMessages && !note) {
        const empty = document.createElement("div");
        empty.className = "empty";
        empty.textContent = "Nothing yet.";
        pane.transcript.append(empty);
      }
    }
    const thread = $("thread");
    const has = thread.querySelector(".msg");
    const note = thread.querySelector(".empty");
    if (has && note) note.remove();
    if (!has && !note) {
      const empty = document.createElement("div");
      empty.className = "empty";
      empty.textContent = "Nothing yet.";
      thread.append(empty);
    }
  }

  /** Draw the live reply being written, appending rather than rebuilding. */
  function drawLive() {
    if (!state) return;
    for (const [index, pane] of panes().entries()) {
      const seat = state.seats[index];
      if (!seat) continue;
      const live = state.live.find((l) => l.seatID === seat.id);
      const existing = pane.transcript.querySelector(".msg.live");

      if (!live || (!live.isGenerating && !live.text && !live.reasoning)) {
        if (existing) existing.remove();
        continue;
      }

      let el = existing;
      if (!el) {
        el = document.createElement("div");
        el.className = "msg live";
        el.dataset.seat = String(index);
        el.dataset.kind = "chat";
        el.innerHTML =
          `<div class="msg-head"><span class="msg-who">${seat.name.toUpperCase()}</span>` +
          `<span class="msg-time">writing…</span></div>` +
          `<div class="msg-body caret"></div>`;
        pane.transcript.append(el);
      }
      const body = el.querySelector(".msg-body");
      // Only touch the DOM when the text has actually grown.
      if (body.dataset.length !== String(live.text.length)) {
        body.innerHTML = bodyHTML(live.text || "");
        body.dataset.length = String(live.text.length);
      }
      body.classList.toggle("caret", live.isGenerating);
      el.querySelector(".msg-time").textContent = live.isGenerating ? "writing…" : formatTime(new Date().toISOString());

      // Thinking is shown only when asked for, and only while there is any.
      let thinking = el.querySelector(".thinking");
      const wantThinking = $("thinking").checked && live.reasoning;
      if (wantThinking) {
        if (!thinking) {
          thinking = document.createElement("div");
          thinking.className = "thinking";
          el.append(thinking);
        }
        if (thinking.dataset.length !== String(live.reasoning.length)) {
          thinking.textContent = live.reasoning;
          thinking.dataset.length = String(live.reasoning.length);
          thinking.scrollTop = thinking.scrollHeight;
        }
      } else if (thinking) {
        thinking.remove();
      }
    }
    if (follow) scrollToBottom();
  }

  function scrollToBottom() {
    for (const container of [...panes().map((p) => p.transcript), $("thread")]) {
      container.scrollTop = container.scrollHeight;
    }
  }

  // ── State → interface ───────────────────────────────────────────────────────────

  function apply(next) {
    const first = state === null;
    state = next;

    if (first) {
      $("topic").value = next.topic || "";
    }
    drawMessages();
    drawLive();
    drawControls();
    drawSeats();
    drawAttachments();
    drawContext();
    if (first && next.messages.length) scrollToBottom();
  }

  function drawControls() {
    const running = state.isRunning || state.status === "Paused";
    $("start").textContent = state.messages.length ? "Restart" : "Start";
    $("start").disabled = false;
    $("pause").disabled = !state.isRunning;
    $("pause").textContent = state.status === "Paused" ? "Resume" : "Pause";
    $("stop").disabled = !running;
    $("clear").disabled = state.messages.length === 0 && !running;
    $("save").disabled = state.messages.length === 0;
    $("condense").disabled = state.messages.length === 0;
    $("send").disabled = !state.isRunning && !state.isPaused;
    $("topic").disabled = state.messages.length > 0;
    $("attach").disabled = !state.canAttach;
    $("files").disabled = !state.canAttach;

    const pill = $("status");
    pill.textContent = state.status;
    pill.className = "pill" +
      (state.isRunning ? " running" : state.status === "Paused" ? " paused" :
       state.status.startsWith("Failed") ? " failed" : "");

    $("counts").textContent = `${state.turnsCompleted} turn${state.turnsCompleted === 1 ? "" : "s"}`;

    if (state.error) toast(state.error);
  }

  function drawSeats() {
    for (const [index, pane] of panes().entries()) {
      const seat = state.seats[index];
      if (!seat) continue;
      const nameEl = pane.root.querySelector(".name");
      if (nameEl.contentEditable !== "true") nameEl.textContent = seat.name;
      pane.root.querySelector(".meta").textContent =
        `${seat.modelShortName} · ${seat.backend === "mlx" ? "MLX" : "API"} · ${seat.personaName}`;
      const live = state.live.find((l) => l.seatID === seat.id);
      const stateEl = pane.root.querySelector(".state");
      const busy = live && live.isGenerating;
      stateEl.className = "state" + (busy ? " live" : "");
      stateEl.textContent = busy ? (live.activity || "thinking…") : (seat.thinking === "off" ? "ready" : `ready · ${seat.thinking}`);
      pane.root.querySelector(".params").textContent =
        `temp ${seat.temperature.toFixed(2)} · top-p ${seat.topP.toFixed(2)} · top-k ${seat.topK} · ` +
        `min-p ${seat.minP.toFixed(1)} · pres ${Math.abs(seat.presencePenalty ?? 0).toFixed(1)} · ` +
        `max ${Math.round(seat.maxTokens / 1024)}k tok${seat.webSearch ? " · web" : ""} · ${seat.vision ? "vision" : "no vision"}`;
    }
    $("persona-summary").textContent = state.seats.map((s) => `${s.name}: ${s.personaName}`).join("   ↔   ");

    const note = $("vision-note");
    if (state.imagesAllowed) {
      note.hidden = true;
    } else {
      const blind = state.seats.filter((s) => !s.vision).map((s) => s.name);
      note.hidden = false;
      note.textContent = `Images hidden — cannot see: ${blind.join(", ")}`;
    }
  }

  function drawAttachments() {
    const chips = $("chips");
    chips.textContent = "";
    for (const doc of state.attachments) {
      const chip = document.createElement("span");
      chip.className = "chip";
      const name = document.createElement("b");
      name.textContent = doc.name;
      const detail = document.createElement("span");
      detail.textContent = `${doc.summary}${doc.wasTruncated ? " · shortened" : ""} · ${doc.tokens} tok`;
      const remove = document.createElement("button");
      remove.textContent = "✕";
      remove.title = `Remove ${doc.name}`;
      remove.disabled = !state.canAttach;
      remove.onclick = async () => {
        try {
          apply(await api.post("/api/attachments/remove", { value: doc.id }));
        } catch (error) { toast(error.message); }
      };
      chip.append(name, detail, remove);
      chips.append(chip);
    }
  }

  function drawContext() {
    const pct = Math.round(state.contextFraction * 100);
    $("context").textContent =
      `ctx ${compact(state.contextTokens)}/${compact(state.contextWindow)} · ${pct}% ` +
      `(condense at ${Math.round(state.compactThreshold * 100)}%)`;
  }

  function compact(n) {
    if (n >= 1000000) return (n / 1000000).toFixed(1) + "M";
    if (n >= 1000) return (n / 1000).toFixed(1) + "k";
    return String(n);
  }

  let toastTimer = null;
  function toast(message, good = false) {
    const el = $("toast");
    el.textContent = message;
    el.className = "toast" + (good ? " good" : "");
    el.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { el.hidden = true; }, 6000);
  }

  // ── Commands ────────────────────────────────────────────────────────────────────

  async function run(fn) {
    try {
      const next = await fn();
      if (next && next.seats) apply(next);
    } catch (error) {
      toast(error.message);
    }
  }

  function wire() {
    $("start").onclick = () => run(() => api.post("/api/start"));
    $("pause").onclick = () => run(() =>
      api.post(state && state.status === "Paused" ? "/api/resume" : "/api/pause"));
    $("stop").onclick = () => run(() => api.post("/api/stop"));
    $("clear").onclick = () => run(() => api.post("/api/reset"));
    $("condense").onclick = () => run(() => api.post("/api/compact"));

    $("topic").addEventListener("change", () => {
      const value = $("topic").value.trim();
      if (!value || (state && value === state.topic)) return;
      run(() => api.post("/api/topic", { topic: value }));
    });

    $("thinking").onchange = () =>
      run(() => api.post("/api/settings", { showReasoning: $("thinking").checked }));

    $("send").onclick = send;
    $("message").addEventListener("keydown", (event) => {
      // Return sends; Shift-Return is a newline, as in every other message box.
      if (event.key === "Enter" && !event.shiftKey) {
        event.preventDefault();
        send();
      }
    });

    $("save").onclick = save;

    $("attach").onclick = () => $("files").click();
    $("files").onchange = (event) => addFiles([...event.target.files]);

    $("layout-split").onclick = () => setLayout("split");
    $("layout-thread").onclick = () => setLayout("thread");
    setLayout(layout);

    // Renaming: a double-click, or a press of Return on the focused button, so it is
    // reachable without a mouse.
    for (const button of document.querySelectorAll(".name")) {
      button.addEventListener("dblclick", () => startRename(button));
      button.addEventListener("keydown", (event) => {
        if (event.key === "Enter") { event.preventDefault(); startRename(button); }
      });
    }

    // Only auto-scroll while the reader is already at the bottom.
    for (const container of [...panes().map((p) => p.transcript), $("thread")]) {
      container.addEventListener("scroll", () => {
        const distance = container.scrollHeight - container.scrollTop - container.clientHeight;
        follow = distance < 40;
      });
    }

    window.addEventListener("keydown", (event) => {
      if (event.metaKey || event.ctrlKey) {
        if (event.key === "s") { event.preventDefault(); save(); }
        if (event.key === "Enter") { event.preventDefault(); $("start").click(); }
      }
    });
  }

  async function send() {
    const box = $("message");
    const text = box.value.trim();
    if (!text) return;
    box.value = "";
    autosize(box);
    await run(() => api.post("/api/message", { text }));
  }

  function autosize(box) {
    box.style.height = "auto";
    box.style.height = Math.min(box.scrollHeight, 96) + "px";
  }

  function startRename(button) {
    if (state && !state.canAttach) { toast("Names are fixed once the conversation has started."); return; }
    const index = Number(button.dataset.rename);
    const seat = state.seats[index];
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
      if (event.key === "Enter") { event.preventDefault(); finish(true); }
      if (event.key === "Escape") { event.preventDefault(); finish(false); }
    };
    button.addEventListener("blur", onBlur);
    button.addEventListener("keydown", onKey);
  }

  function setLayout(next) {
    layout = next;
    document.body.dataset.layout = next;
    localStorage.setItem("chatbots.layout", next);
    $("layout-split").classList.toggle("on", next === "split");
    $("layout-thread").classList.toggle("on", next === "thread");
    if (next === "thread") {
      // The thread is rebuilt from the state so it is always in order.
      $("thread").textContent = "";
      rendered.clear();
      for (const pane of panes()) pane.transcript.textContent = "";
      drawMessages();
      drawLive();
      scrollToBottom();
    }
  }

  async function addFiles(files) {
    if (!files.length) return;
    for (const file of files) {
      try {
        const buffer = await file.arrayBuffer();
        // Base64 rather than multipart: one code path on both sides, and the files are
        // documents rather than media.
        let binary = "";
        const bytes = new Uint8Array(buffer);
        const chunk = 0x8000;
        for (let i = 0; i < bytes.length; i += chunk) {
          binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
        }
        const next = await api.post("/api/attachments", {
          filename: file.name,
          content: btoa(binary),
        });
        apply(next);
        toast(`Added ${file.name}`, true);
      } catch (error) {
        toast(`${file.name}: ${error.message}`);
      }
    }
    $("files").value = "";
  }

  function save() {
    if (!state) return;
    const pad = (n) => String(n).padStart(2, "0");
    const stamp = (iso) => {
      const d = new Date(iso);
      return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
             `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
    };
    const now = new Date();
    let out = "ChatBots — conversation log\\n";
    out += `Topic: ${state.topic || "(none)"}\\n`;
    for (const seat of state.seats) out += `Participant: ${seat.name} (${seat.modelShortName})\\n`;
    out += `Exported: ${stamp(now)}\\n\\n${"-".repeat(72)}\\n`;
    for (const message of state.messages) {
      if (message.kind === "introduction") continue;
      const who = labelFor(message, seatIndexOf(message));
      out += `\\n[${stamp(message.timestamp)}] ${who}\\n`;
      out += message.text.split("\\n").map((line) => "    " + line).join("\\n") + "\\n";
    }
    const blob = new Blob([out], { type: "text/plain;charset=utf-8" });
    const a = document.createElement("a");
    const slug = (state.topic || "conversation").replace(/[^a-zA-Z0-9 ]/g, "").trim()
      .replace(/\\s+/g, "-").slice(0, 60);
    a.href = URL.createObjectURL(blob);
    a.download = `ChatBots ${slug} ${stamp(now).replace(/:/g, "-")}.txt`;
    a.click();
    URL.revokeObjectURL(a.href);
  }

  // ── Events ──────────────────────────────────────────────────────────────────────

  function listen() {
    const source = new EventSource("/api/events");
    source.addEventListener("snapshot", (event) => {
      $("status").title = "";
      apply(JSON.parse(event.data));
    });
    source.addEventListener("turn", () => {
      // A new turn is in the state that follows; the event exists so a front end can react
      // immediately rather than waiting for the next snapshot.
    });
    source.onerror = () => {
      // EventSource reconnects on its own. Saying so would be noise; saying it once is not.
      toast("Lost the connection to the server — reconnecting…");
    };
  }

  // ── Start ───────────────────────────────────────────────────────────────────────

  wire();
  api.get("/api/state").then(apply).catch((error) => toast(error.message));
  listen();
})();

"""

}
