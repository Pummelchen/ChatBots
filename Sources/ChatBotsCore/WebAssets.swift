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
<!-- viewport-fit=cover so a notched phone can be detected and inset properly; the CSS only
     applies the safe-area insets on a phone profile, where they matter. -->
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#101014" media="(prefers-color-scheme: dark)">
<meta name="theme-color" content="#f4f4f7" media="(prefers-color-scheme: light)">
<meta name="mobile-web-app-capable" content="yes">
<title>ChatBots</title>
<link rel="stylesheet" href="/style.css">
</head>
<!-- The attributes the client fills in. `data-device` is derived from the live viewport and
     drives every responsive rule; `data-layout` is the user's mode choice. Both are set by
     app.js before first paint where possible, and CSS has sane defaults if it is not. -->
<body data-device="phone" data-layout="thread" data-profile="unknown">

<header class="bar">
  <div class="topic-row">
    <label class="lab" for="topic">
      <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M2 3h12v8H6l-3 3v-3H2z"/></svg>
      <span class="lab-text">Topic</span>
    </label>
    <input id="topic" type="text" autocomplete="off" spellcheck="false"
           placeholder="What should the models discuss?">
    <div class="transport">
      <button id="start" class="primary">Start</button>
      <button id="pause" disabled>Pause</button>
      <button id="stop" disabled>Stop</button>
      <button id="save" disabled title="Download the conversation log">Save</button>
      <button id="kept" title="Reopen a conversation the engine kept">Kept</button>
      <button id="lineup" title="Choose who is in the room, or let the app choose">Line-up</button>
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
    <span class="personas" id="persona-summary"></span>
    <div class="spacer"></div>
    <label class="toggle" title="Stream the models' thinking into the panes">
      <input id="thinking" type="checkbox" checked> <span class="toggle-text">Show thinking</span>
    </label>
    <!-- The mode decides which persona library the pickers offer, so it belongs next to
         them rather than buried in a sheet. -->
    <div class="seg" role="group" aria-label="Mode">
      <button id="mode-entertainment" class="on" title="Give personalities a topic and watch them argue">Show</button>
      <button id="mode-research" title="Specialists investigate a question">Research</button>
    </div>
    <!-- Auto follows the detected device; the other two override it and are remembered. -->
    <div class="seg" role="group" aria-label="View mode">
      <button id="view-auto" class="on" title="Follow this device automatically">Auto</button>
      <button id="view-phone" title="Force the single-column phone layout">Phone</button>
      <button id="view-desktop" title="Force the two-pane desktop layout">Desktop</button>
    </div>
  </div>
</header>

<main id="stage">
  <!-- One pane per seat, built by the client: the seat count is 2, 3 or 4, and hard-coding
       two of them was what made a 4-seat room impossible. The template is cloned. -->
  <template id="pane-template">
    <section class="pane">
      <div class="pane-head">
        <span class="dot"></span>
        <div class="who">
          <button class="name" title="Press to rename"></button>
          <span class="meta"></span>
        </div>
        <div class="spacer"></div>
        <span class="state"></span>
      </div>
      <!-- The persona picker. In the pane header rather than in a settings sheet, because
           who is speaking is the thing a viewer most wants to change. -->
      <div class="persona-row">
        <button class="persona-picker" title="Change who this participant is"></button>
      </div>
      <div class="params"></div>
      <div class="transcript"></div>
    </section>
  </template>

  <div id="thread" class="thread" hidden></div>
</main>

<footer class="bar footer">
  <textarea id="message" rows="1" placeholder="Message…"></textarea>
  <button id="send" class="primary" disabled>Send</button>
  <div class="spacer"></div>
  <button id="condense" disabled title="Summarise the older turns now">Condense</button>
  <span id="context" class="note mono">ctx —</span>
</footer>

<!-- Shown only while a research session is running. -->
<div id="research-bar" class="research-bar" hidden>
  <span id="research-depth" class="pill"></span>
  <span id="research-progress" class="note"></span>
  <div class="spacer"></div>
  <div class="seg" role="group" aria-label="Research budget">
    <button id="depth-quick" title="5–10 minutes">Quick</button>
    <button id="depth-standard" title="20–30 minutes">Standard</button>
    <button id="depth-deep" title="45–60 minutes">Deep</button>
  </div>
</div>

<!-- The deliverable. Its own panel rather than another message in the argument. -->
<div id="report-panel" class="report-panel" hidden>
  <div class="report-head">
    <b>Research report</b>
    <span id="report-meta" class="note"></span>
    <div class="spacer"></div>
    <button id="report-download" class="small">Download .md</button>
    <button id="report-close" class="small">Close</button>
  </div>
  <div id="report-body" class="report-body"></div>
</div>

<!-- Every conversation is kept on disk as it runs, so this is how one comes back. -->
<div id="kept-panel" class="report-panel" hidden>
  <div class="report-head">
    <b>Kept conversations</b>
    <span id="kept-meta" class="note"></span>
    <div class="spacer"></div>
    <button id="kept-refresh" class="small">Refresh</button>
    <button id="kept-new" class="small">New</button>
    <button id="kept-close" class="small">Close</button>
  </div>
  <div id="kept-body" class="report-body"></div>
</div>

<!-- Who is in the room, and what they are put in front of. One panel, because a panel is the
     wrong room for the wrong question and the pairing is the thing worth choosing. -->
<div id="lineup-panel" class="report-panel" hidden>
  <div class="report-head">
    <b>Line-up</b>
    <span id="lineup-meta" class="note"></span>
    <div class="spacer"></div>
    <button id="lineup-surprise" class="small">Surprise me</button>
    <button id="lineup-close" class="small">Close</button>
  </div>
  <div id="lineup-body" class="report-body"></div>
</div>

<div id="toast" class="toast" hidden></div>
<div id="profile-badge" class="profile-badge" hidden></div>

<script src="/app.js"></script>
</body>
</html>

"""

    static let styleCSS = """
/* ChatBots — the web interface
 *
 * Mobile first, because that is where the layout is hardest. The phone case has to fit a
 * conversation, a topic field and a message box into about 360 by 780 points without the
 * keyboard eating the transcript, and everything a desktop needs is a relaxation of that
 * rather than the other way round.
 *
 * Three things drive the responsive behaviour, in this order:
 *
 *   1. `data-device` on <body> — phone, tablet or desktop — set from the live viewport.
 *      A user override replaces the detected value, which is why it is an attribute rather
 *      than a media query alone: CSS media queries cannot be overridden from a setting.
 *   2. `--vw` and `--vh` custom properties, written from `window.visualViewport`. On iOS
 *      `100vh` is the height *without* the browser chrome, so a full-height phone layout
 *      built on `vh` is covered by the address bar. `--vh` is the real visible height.
 *   3. Safe-area insets, so a notch or a home indicator does not sit on top of the text.
 *
 * The two-pane view is a *privilege* of a wide screen, not the default: below the tablet
 * breakpoint the interface is one column, which is the WhatsApp shape.
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
  /* A third and fourth seat need their own hues: telling two blues apart under pressure is
     harder than telling blue from amber. */
  --seat-c: #f2a03d;
  --seat-d: #3ecf8e;
  --mod: #ffc44d;
  --danger: #ff6b6b;
  --radius: 10px;
  /* Minimum comfortable touch target. Apple asks for 44pt, Google for 48dp; 44 CSS px
     satisfies both in practice and is what the buttons below are built to. */
  --tap: 44px;
  --pad: calc(12px * var(--scale));
  --font: calc(13.5px * var(--scale));
  --font-small: calc(11px * var(--scale));
  --font-tiny: calc(10px * var(--scale));
  /* Fallbacks for the first paint, before app.js has measured anything. */
  --vw: 100vw;
  --vh: 100vh;
  /* The width the layout composes against. Normally the viewport; a forced phone view sets
     it to a phone's width so the composition is genuinely phone-shaped. */
  --measure: 100vw;
  --safe-top: 0px;
  --safe-bottom: 0px;
  --safe-left: 0px;
  --safe-right: 0px;
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

/* Text scales with the screen rather than the device name: a 360-point Android entry model
   and a 360-point flagship have the same room and should not look different. */
@media (min-width: 700px)  { :root { --scale: 1; } }
@media (min-width: 1100px) { :root { --scale: 1.05; } }
@media (min-width: 1700px) { :root { --scale: 1.15; } }
@media (max-width: 390px)  { :root { --scale: 0.95; } }
@media (max-width: 340px)  { :root { --scale: 0.9; } }

* { box-sizing: border-box; }

/* Several panels below set `display`, which overrides the browser's default styling for the
   `hidden` attribute — an element with `display: flex` from a class stays visible even when
   hidden. Found by looking at a capture: the research report panel was showing over an
   entertainment conversation, with nothing in it. */
[hidden] { display: none !important; }

html, body {
  height: 100%;
  margin: 0;
  overflow: hidden;
  background: var(--bg);
  color: var(--text);
  font: var(--font)/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI",
        system-ui, sans-serif;
  -webkit-font-smoothing: antialiased;
  /* Stops iOS from inflating text in landscape, which breaks a carefully fitted layout. */
  -webkit-text-size-adjust: 100%;
}

body {
  display: flex;
  flex-direction: column;
  /* The real visible height, not 100vh. */
  height: var(--vh);
  /* Nothing on the page is wider than the screen; if something is, the transcript scrolls
     inside its own container rather than the whole interface sliding sideways. This is a
     guard, not the fix — the rows below wrap so it should never trigger. */
  overflow-x: hidden;
  max-width: var(--vw);
  /* A phone is used with a thumb: taps should not select text or show a blue flash. */
  -webkit-tap-highlight-color: transparent;
}

/* ── Controls ─────────────────────────────────────────────────────────────────────── */

.bar {
  flex: 0 0 auto;
  display: flex;
  flex-direction: column;
  gap: calc(7px * var(--scale));
  padding: var(--pad);
  background: var(--bg-raised);
  border-bottom: 1px solid var(--line);
}

.footer {
  border-bottom: none;
  border-top: 1px solid var(--line);
  flex-direction: row;
  align-items: center;
  gap: calc(7px * var(--scale));
  /* Clear the home indicator so the message box is not under it. */
  padding-bottom: calc(var(--pad) + var(--safe-bottom));
}

.topic-row, .attach-row, .control-row {
  display: flex;
  align-items: center;
  gap: calc(7px * var(--scale));
  flex-wrap: wrap;
  /* A flex row refuses to shrink below its content unless told to. Without this a long
     label or a row of buttons pushes the whole page wider than the phone. */
  min-width: 0;
  max-width: 100%;
}

/* The label text is dropped on a phone to buy width for the topic itself; the icon carries
   the meaning and the placeholder says the rest. */
body[data-device="phone"] .lab-text { display: none; }

.lab {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  color: var(--text-dim);
  font-size: var(--font-small);
  font-weight: 600;
  white-space: nowrap;
}

.lab svg { width: 15px; height: 15px; fill: currentColor; flex: 0 0 auto; }

input[type="text"], textarea {
  font: inherit;
  /* 16px minimum: any smaller and iOS Safari zooms the page on focus, which is
     disorienting and leaves the layout scrolled. */
  font-size: max(16px, var(--font));
  color: var(--text);
  background: var(--bg-sunken);
  border: 1px solid var(--line);
  border-radius: 9px;
  padding: calc(8px * var(--scale)) calc(10px * var(--scale));
  min-width: 0;
}

#topic { flex: 1 1 140px; min-width: 0; }

textarea {
  flex: 1 1 auto;
  min-width: 0;
  resize: none;
  max-height: calc(96px * var(--scale));
  line-height: 1.35;
}

input:focus-visible, textarea:focus-visible, button:focus-visible {
  outline: 2px solid var(--seat-a);
  outline-offset: 1px;
}

input:disabled, textarea:disabled { opacity: 0.6; }

button {
  font: inherit;
  font-size: var(--font-small);
  color: var(--text);
  background: var(--bg-sunken);
  border: 1px solid var(--line);
  border-radius: 9px;
  padding: calc(7px * var(--scale)) calc(11px * var(--scale));
  cursor: pointer;
  white-space: nowrap;
  /* Comfortable on a touchscreen without looking oversized with a mouse. */
  min-height: calc(var(--tap) * 0.78);
}

button:hover:not(:disabled) { background: var(--line); }
button:active:not(:disabled) { transform: scale(0.97); }
button:disabled { opacity: 0.42; cursor: default; }

button.primary {
  background: var(--seat-a);
  border-color: transparent;
  color: #06121f;
  font-weight: 600;
}

button.small { font-size: var(--font-tiny); }

/* A finger needs a bigger target than a cursor. */
body[data-device="phone"] button { min-height: var(--tap); padding-inline: calc(13px * var(--scale)); }

.transport { display: flex; gap: calc(6px * var(--scale)); flex: 0 0 auto; flex-wrap: wrap; }

.spacer { flex: 1 1 auto; }

.pill {
  font-size: var(--font-small);
  font-weight: 600;
  padding: calc(5px * var(--scale)) calc(10px * var(--scale));
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

.toggle {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: var(--font-small);
  color: var(--text-dim);
  white-space: nowrap;
  min-height: var(--tap);
}

.seg { display: flex; border: 1px solid var(--line); border-radius: 9px; overflow: hidden; }
.seg button { border: none; border-radius: 0; background: transparent; padding-inline: calc(9px * var(--scale)); }
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
  padding: calc(4px * var(--scale)) calc(5px * var(--scale)) calc(4px * var(--scale)) calc(11px * var(--scale));
  font-size: var(--font-tiny);
  max-width: 100%;
  min-height: calc(var(--tap) * 0.7);
}

.chip b { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 30ch; }
.chip span { color: var(--text-faint); white-space: nowrap; }
.chip button { border: none; background: transparent; padding: 0 6px; font-size: var(--font); line-height: 1; min-height: 0; }

/* ── Panes ────────────────────────────────────────────────────────────────────────── */

#stage {
  flex: 1 1 auto;
  min-height: 0;
  display: grid;
  grid-template-columns: 1fr;
  gap: 1px;
  background: var(--line);
}

/* Two columns is the comfortable case; three and four are allowed on a wide screen but each
   pane stays wide enough to read, which is why the columns are capped rather than made
   equal. Below the tablet breakpoint everything is one column, whatever the seat count: a
   180-point pane is not a conversation. */
body[data-device="tablet"] #stage { grid-template-columns: repeat(2, minmax(0, 1fr)); }
body[data-device="desktop"] #stage {
  grid-template-columns: repeat(auto-fit, minmax(min(380px, 100%), 1fr));
}
/* With four seats on a modest desktop, two rows of two reads better than four narrow
   columns. */
body[data-device="desktop"][data-seats="4"] #stage {
  grid-template-columns: repeat(2, minmax(0, 1fr));
}
body[data-device="desktop"][data-seats="3"] #stage {
  grid-template-columns: repeat(3, minmax(0, 1fr));
}

/* The single-column shape: one conversation, both participants in it. */
body[data-layout="thread"] #stage { grid-template-columns: 1fr; }
body[data-layout="thread"] .pane { display: none; }
body[data-layout="thread"] #thread { display: flex; }

/* A narrow *tablet* still gets one column, because two 400-point panes are not useful. */
@media (max-width: 720px) {
  body[data-device="tablet"] #stage { grid-template-columns: 1fr; }
  body[data-device="tablet"] .pane { display: none; }
  body[data-device="tablet"] #thread { display: flex; }
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
  width: calc(26px * var(--scale));
  height: calc(26px * var(--scale));
  border-radius: 50%;
  display: grid;
  place-items: center;
  font-size: var(--font-tiny);
  font-weight: 700;
  color: #06121f;
  background: var(--seat-a);
}

.pane:nth-of-type(2) .dot { background: var(--seat-b); }

.who { min-width: 0; flex: 1 1 auto; }

.name {
  display: block;
  background: none;
  border: none;
  padding: 0;
  font-size: calc(15px * var(--scale));
  font-weight: 600;
  color: var(--text);
  text-align: left;
  max-width: 100%;
  overflow: hidden;
  text-overflow: ellipsis;
  min-height: 0;
}

.name[contenteditable="true"] {
  background: var(--bg-sunken);
  border: 1px solid var(--seat-a);
  border-radius: 6px;
  padding: 1px 6px;
  outline: none;
}

.meta {
  display: block;
  font-size: var(--font-tiny);
  color: var(--text-faint);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

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
  -webkit-overflow-scrolling: touch;
}

.params::-webkit-scrollbar { display: none; }

/* The transcript scrolls, the page does not: a phone should not scroll the whole
   interface when a long reply arrives. */
.transcript, .thread {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  overflow-x: hidden;
  -webkit-overflow-scrolling: touch;
  overscroll-behavior: contain;
  padding: var(--pad);
  display: flex;
  flex-direction: column;
  gap: calc(10px * var(--scale));
}

.thread { display: none; }

/* ── Messages ─────────────────────────────────────────────────────────────────────── */

.msg {
  border-left: 3px solid var(--line);
  padding: calc(8px * var(--scale)) calc(11px * var(--scale));
  border-radius: 0 9px 9px 0;
  background: var(--bg-raised);
  animation: fade 0.18s ease-out;
  /* Long URLs and code should wrap rather than widen the transcript. */
  overflow-wrap: anywhere;
}

@keyframes fade { from { opacity: 0; transform: translateY(3px); } to { opacity: 1; } }

.msg[data-kind="topic"], .msg[data-kind="steering"], .msg[data-kind="direction"] { border-left-color: var(--mod); }
.msg[data-kind="summary"] { border-left-color: var(--text-faint); font-style: italic; }
.msg[data-kind="tool"] { border-left-color: var(--line); background: transparent; }
.msg[data-seat="0"] { border-left-color: var(--seat-a); }
.msg[data-seat="1"] { border-left-color: var(--seat-b); }

.msg-head {
  display: flex;
  align-items: baseline;
  gap: 8px;
  margin-bottom: 3px;
  flex-wrap: wrap;
}

.msg-who { font-size: var(--font-small); font-weight: 700; letter-spacing: 0.02em; }
.msg[data-seat="0"] .msg-who { color: var(--seat-a); }
.msg[data-seat="1"] .msg-who { color: var(--seat-b); }
.msg[data-kind="topic"] .msg-who, .msg[data-kind="steering"] .msg-who, .msg[data-kind="direction"] .msg-who { color: var(--mod); }
.msg-time { font-size: var(--font-tiny); color: var(--text-faint); font-family: ui-monospace, Menlo, monospace; }
.msg-body { white-space: pre-wrap; overflow-wrap: anywhere; }
.msg-body p { margin: 0 0 0.6em; }
.msg-body p:last-child { margin-bottom: 0; }
.msg-body code { font-family: ui-monospace, Menlo, monospace; font-size: 0.92em; background: var(--bg-sunken); padding: 0 4px; border-radius: 4px; }

.msg.live { opacity: 0.96; }
.msg .thinking {
  margin-top: 6px;
  padding: 6px 9px;
  border-radius: 7px;
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
  transform: translateX(-50%);
  background: var(--bg-raised);
  border: 1px solid var(--line);
  border-left: 3px solid var(--danger);
  border-radius: 9px;
  padding: 10px 14px;
  font-size: var(--font-small);
  box-shadow: 0 8px 28px rgba(0,0,0,0.4);
  max-width: min(560px, calc(var(--vw) - 24px));
  z-index: 20;
  /* Above the message box, and above the home indicator. */
  bottom: calc(84px * var(--scale) + var(--safe-bottom));
}

.toast.good { border-left-color: var(--seat-a); }

/* The thread shape: both participants in one column, like a messaging app. */
.thread .msg { max-width: min(680px, 100%); }
.thread .msg[data-seat="1"] { align-self: flex-end; }

/* A debug label, shown only when ?profile is in the URL. */
.profile-badge {
  position: fixed;
  top: calc(4px + var(--safe-top));
  right: 6px;
  font-size: 9px;
  font-family: ui-monospace, Menlo, monospace;
  color: var(--text-faint);
  background: var(--bg-sunken);
  border: 1px solid var(--line);
  border-radius: 5px;
  padding: 2px 5px;
  z-index: 30;
  pointer-events: none;
}

@media (prefers-reduced-motion: reduce) {
  .msg { animation: none; }
  .transcript, .thread { scroll-behavior: auto; }
  .caret::after { animation: none; }
  button:active:not(:disabled) { transform: none; }
}

/* ── Phone-specific refinements ───────────────────────────────────────────────────── */

/* On a phone the controls are a means to an end: the conversation is the point. So the
   attachment row only appears once there is something attached, and the transcript gets the
   height instead. The class is set by the client, because `:empty` cannot match a row that
   always contains hidden inputs. */
body[data-device="phone"] .attach-row { display: none; }
body[data-device="phone"] .attach-row.has-chips { display: flex; }
body[data-device="phone"] .personas { display: none; }

/* On a phone the model parameters are trivia; they are still reachable by overriding to
   the desktop layout, which is where someone would look for them. */
body[data-device="phone"] .params { display: none; }
body[data-device="phone"] .pane .params { display: none; }

body[data-device="phone"] .control-row {
  gap: 6px;
  /* The status, the mode switch and the thinking toggle all fit, but only if this row is
     allowed to wrap. */
  flex-wrap: wrap;
}

/* The transport buttons are the primary control on a phone, so they get their own line
   rather than competing with the topic field for one. */
body[data-device="phone"] .topic-row { row-gap: 6px; }
body[data-device="phone"] .transport { flex: 1 1 100%; justify-content: flex-start; }

/* The context meter is useful but not worth a row on a phone; it moves next to the status. */
body[data-device="phone"] .footer .mono { display: none; }

/* Landscape phone: the header alone can eat the screen, so it is compacted. */
@media (orientation: landscape) and (max-height: 480px) {
  body[data-device="phone"] .attach-row { display: none; }
  body[data-device="phone"] .params { display: none; }
  body[data-device="phone"] .control-row { padding-block: 2px; }
  body[data-device="phone"] .footer .note { display: none; }
}

/* The footer is the most constrained row on a phone: a text box, a send button and, on a
   desktop, a condense button and the context meter. Only the first two are essential on a
   handset, so the others step aside and the message box gets the width. */
body[data-device="phone"] .footer { gap: 6px; }
body[data-device="phone"] .footer #condense { display: none; }
body[data-device="phone"] .footer #send { flex: 0 0 auto; }
body[data-device="phone"] .footer #message { flex: 1 1 auto; }

/* A notched phone in landscape puts the notch over one edge; inset the whole frame. */
@media (orientation: landscape) {
  body[data-device="phone"] .bar,
  body[data-device="phone"] .footer { padding-left: calc(var(--pad) + var(--safe-left)); padding-right: calc(var(--pad) + var(--safe-right)); }
}

/* Tablet: keep the two panes but give the controls room to breathe. */
body[data-device="tablet"] .personas { display: inline; }
body[data-device="tablet"] .toggle-text { display: inline; }


/* ── Research session ─────────────────────────────────────────────────────────────── */

/* The budget controls only mean anything before the run, so the bar appears with the
   session and disappears with the report. */
.research-bar {
  display: flex;
  align-items: center;
  gap: calc(8px * var(--scale));
  padding: calc(6px * var(--scale)) var(--pad);
  background: var(--bg-sunken);
  border-bottom: 1px solid var(--line);
  flex-wrap: wrap;
}

.research-bar .seg button { padding-inline: calc(8px * var(--scale)); }

/* The report is the deliverable, so it takes the space rather than sitting in the log. */
.report-panel {
  position: fixed;
  left: 50%;
  transform: translateX(-50%);
  top: calc(8px + var(--safe-top));
  bottom: calc(8px + var(--safe-bottom));
  width: min(760px, calc(var(--vw) - 16px));
  display: flex;
  flex-direction: column;
  background: var(--bg-raised);
  border: 1px solid var(--line);
  border-radius: 12px;
  box-shadow: 0 12px 40px rgba(0, 0, 0, 0.45);
  z-index: 25;
  overflow: hidden;
}

.report-head {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: calc(9px * var(--scale)) var(--pad);
  border-bottom: 1px solid var(--line);
  flex-wrap: wrap;
}

.report-body {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  -webkit-overflow-scrolling: touch;
  padding: var(--pad);
  font-size: var(--font-small);
  line-height: 1.55;
}

.report-body h1 { font-size: calc(17px * var(--scale)); margin: 0 0 10px; }
.report-body h2 {
  font-size: calc(14px * var(--scale));
  margin: 18px 0 6px;
  padding-bottom: 3px;
  border-bottom: 1px solid var(--line);
}
.report-body ul { margin: 0 0 8px; padding-left: 1.2em; }
.report-body li { margin-bottom: 4px; }
.report-body p { margin: 0 0 8px; }
/* The claim labels are the point of the format, so they are emphasised. */
.report-body strong { color: var(--seat-a); }

@media (max-width: 780px) {
  .report-panel { width: calc(var(--vw) - 12px); }
  .report-head .spacer { display: none; }
}

/* The kept list borrows the report panel's shape: same furniture, different contents. */
.kept-row {
  display: flex;
  align-items: flex-start;
  gap: calc(10px * var(--scale));
  padding: calc(8px * var(--scale)) 0;
  border-bottom: 1px solid var(--line);
}
.kept-row:last-child { border-bottom: 0; }
.kept-text { flex: 1 1 auto; min-width: 0; }
.kept-topic {
  font-weight: 600;
  font-size: var(--font-body);
  overflow-wrap: anywhere;
}
.kept-sub {
  color: var(--text-secondary);
  font-size: var(--font-small);
  margin-top: 2px;
  overflow-wrap: anywhere;
}
.kept-meta {
  color: var(--text-faint);
  font-size: var(--font-tiny);
  font-family: ui-monospace, Menlo, monospace;
  margin-top: 3px;
}
.kept-actions { display: flex; gap: 6px; flex: 0 0 auto; }
.kept-empty { color: var(--text-secondary); text-align: center; padding: calc(28px * var(--scale)) 0; }

.lineup-section {
  font-size: var(--font-small);
  font-weight: 700;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: var(--text-secondary);
  margin: calc(14px * var(--scale)) 0 calc(4px * var(--scale));
}
.lineup-section:first-child { margin-top: 0; }
.lineup-row {
  display: flex;
  align-items: flex-start;
  gap: calc(10px * var(--scale));
  padding: calc(7px * var(--scale)) 0;
  border-bottom: 1px solid var(--line);
}
.lineup-row:last-child { border-bottom: 0; }
.lineup-text { flex: 1 1 auto; min-width: 0; }
.lineup-name { font-weight: 600; }
.lineup-note { color: var(--text-secondary); font-size: var(--font-small); margin-top: 2px; }
.lineup-who {
  color: var(--text-faint);
  font-size: var(--font-tiny);
  font-family: ui-monospace, Menlo, monospace;
  margin-top: 3px;
  overflow-wrap: anywhere;
}


/* ── More than two seats ──────────────────────────────────────────────────────────── */

/* Each seat gets its own tint, so a four-way conversation is still readable at a glance.
   Distinct hues rather than shades: telling two blues apart under pressure is harder than
   telling blue from amber. */
.pane[data-seat="2"] .dot { background: var(--seat-c); }
.pane[data-seat="3"] .dot { background: var(--seat-d); }
.msg[data-seat="2"] { border-left-color: var(--seat-c); }
.msg[data-seat="3"] { border-left-color: var(--seat-d); }
.msg[data-seat="2"] .msg-who { color: var(--seat-c); }
.msg[data-seat="3"] .msg-who { color: var(--seat-d); }

@media (max-width: 780px) {
  body[data-device="tablet"] #stage,
  body[data-device="desktop"] #stage { grid-template-columns: 1fr; }
}


/* ── The persona picker ───────────────────────────────────────────────────────────── */

.persona-row {
  flex: 0 0 auto;
  padding: calc(4px * var(--scale)) var(--pad);
  border-bottom: 1px solid var(--line);
}

.persona-picker {
  font: inherit;
  font-size: var(--font-small);
  color: var(--text);
  background: var(--bg-sunken);
  border: 1px solid var(--line);
  border-radius: 8px;
  padding: calc(4px * var(--scale)) calc(9px * var(--scale));
  width: 100%;
  text-align: left;
  min-height: calc(var(--tap) * 0.72);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.persona-picker:disabled { opacity: 0.6; }

/* The list itself. A native-feeling panel rather than a floating dropdown, because it can
   hold the whole cast and works the same with a finger and a mouse. */
.persona-sheet {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.5);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 40;
  padding: 12px;
}

.persona-sheet-inner {
  background: var(--bg-raised);
  border: 1px solid var(--line);
  border-radius: 12px;
  width: min(720px, 100%);
  max-height: min(80vh, 640px);
  display: flex;
  flex-direction: column;
  overflow: hidden;
  box-shadow: 0 14px 40px rgba(0, 0, 0, 0.5);
}

.persona-sheet-head {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: var(--pad);
  border-bottom: 1px solid var(--line);
}

.persona-sheet-body {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  -webkit-overflow-scrolling: touch;
  padding: calc(8px * var(--scale));
}

.persona-group {
  font-size: var(--font-tiny);
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--text-faint);
  margin: calc(10px * var(--scale)) 0 calc(4px * var(--scale));
}

.persona-item {
  display: flex;
  align-items: baseline;
  gap: 8px;
  width: 100%;
  text-align: left;
  background: transparent;
  border: 1px solid transparent;
  border-radius: 8px;
  padding: calc(7px * var(--scale)) calc(9px * var(--scale));
  min-height: var(--tap);
}

.persona-item:hover { background: var(--bg-sunken); }
.persona-item.on { border-color: var(--seat-a); background: var(--bg-sunken); }
.persona-item b { font-weight: 600; white-space: nowrap; }
.persona-item span { color: var(--text-dim); font-size: var(--font-tiny); }

/* On a phone the sheet takes the screen, because a half-height list of 36 characters in a
   centred box is worse than a full-screen one. */
@media (max-width: 600px) {
  .persona-sheet { padding: 0; align-items: flex-end; }
  .persona-sheet-inner { width: 100%; max-height: 88vh; border-radius: 12px 12px 0 0; }
}


/* ── A forced phone view, on a wide screen ────────────────────────────────────────── */

/* `?view=phone` on a desktop browser asks for the phone layout, which means the *shape* of a
   phone and not merely the single column. Everything is composed against `--measure`, which
   the client narrows to a phone's width, and the whole page is centred in a soft frame so it
   reads as a phone rather than as a broken desktop layout. */
body[data-view="phone"] {
  max-width: var(--measure);
  margin-inline: auto;
}

@media (min-width: 700px) {
  body[data-view="phone"] {
    /* A frame, so it is obvious this is deliberate rather than a page that failed to fill
       the window. */
    border-inline: 1px solid var(--line);
    box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.25), 0 18px 60px rgba(0, 0, 0, 0.45);
  }
}

"""

    static let appJS = """
// ChatBots — the web interface
//
// A thin client over the HTTP API. It holds no conversation state of its own beyond what it
// has been told: the server owns the conversation, so a reload, a second tab, or the SwiftUI
// app all see the same thing. Where this does keep a copy — the rendered messages — it exists
// only to avoid rebuilding the transcript on every update.
//
// The responsive part is deliberately *profile driven* rather than purely CSS media queries.
// A media query cannot express "the user asked for the desktop layout on a phone", and it
// cannot tell a 360-point Android entry model from a 360-point flagship — nor does it need
// to, which is the point: the layout branches on width, and the device profiles exist to
// verify that every width in use is covered. `data-device` carries the branch, `--vh` and
// `--vw` carry the measured viewport, and the safe-area insets come from CSS constants that
// only mean anything on a device with a notch.

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

  // ── Screen profile ─────────────────────────────────────────────────────────────────

  const VIEW_MODE_KEY = "chatbots.viewMode";

  /// Breakpoints, in CSS pixels. The tablet boundary is the one that matters: below it two
  /// panes are too narrow to read, which is why a phone gets one column.
  const PHONE_MAX = 719;
  /// How wide a forced phone view is allowed to be, in CSS points. A 430-point column is a
  /// large phone; wider and it stops reading as one.
  const PHONE_VIEWPORT_MAX = 430;
  const TABLET_MAX = 1023;

  const state = {
    /** The conversation, as last reported by the server. */
    snapshot: null,
    /**
     * Whether the transcript should follow new messages. Turned off when the reader scrolls
     * up, so reading back is not yanked away by an arriving reply.
     */
    follow: true,
  };

  /** How the device was detected, for the badge and for the resize report. */
  const screenInfo = { width: 0, height: 0, detected: "phone", matched: null };

  function detectDevice(width) {
    if (width <= PHONE_MAX) return "phone";
    if (width <= TABLET_MAX) return "tablet";
    return "desktop";
  }

  /**
   * The mode the user asked for: "auto", "phone" or "desktop".
   *
   * "Desktop" is offered rather than "tablet" because the two wide layouts are the same;
   * what a user on a phone wants when they override is the two-pane view, and what a user on
   * a desktop wants when they narrow their window is the single column.
   */
  function storedViewMode() {
    try {
      const value = localStorage.getItem(VIEW_MODE_KEY);
      return value === "phone" || value === "desktop" ? value : "auto";
    } catch {
      return "auto";
    }
  }

  let viewMode = storedViewMode();

  /**
   * `?view=phone|desktop|auto` forces a mode for this load only.
   *
   * It exists for the capture harness: a screenshot has to be reproducible, and it should
   * not depend on what happens to be in localStorage on the machine taking it. It is also
   * handy for sharing a link to a particular view.
   */
  function urlViewMode() {
    const value = new URLSearchParams(location.search).get("view");
    return value === "phone" || value === "desktop" || value === "auto" ? value : null;
  }

  /** Measure the real visible viewport and publish it to CSS. */
  function measureViewport() {
    // `visualViewport` is the honest number on mobile: it excludes the browser chrome that
    // `100vh` includes, which is why a layout built on `vh` is covered by the address bar on
    // iOS. The fallbacks keep older browsers working.
    const vv = window.visualViewport;
    const width = Math.round(vv ? vv.width : window.innerWidth);
    const height = Math.round(vv ? vv.height : window.innerHeight);
    const root = document.documentElement;

    // A forced phone view on a wide screen composes against a phone-sized width rather than
    // the browser's. Without this, "phone layout" on a 1400-point window is a very wide page
    // with the single-column layout — technically correct and nothing like a phone.
    const composedWidth = (viewMode === "phone" && width > PHONE_VIEWPORT_MAX)
      ? PHONE_VIEWPORT_MAX
      : width;

    root.style.setProperty("--vw", composedWidth + "px");
    root.style.setProperty("--vh", height + "px");
    root.style.setProperty("--measure", composedWidth + "px");

    screenInfo.width = width;
    screenInfo.height = height;

    // A phone in landscape is wider than PHONE_MAX and would otherwise be treated as a
    // tablet, which puts two columns on a 390-point-tall screen. Touch plus a short edge is
    // the signal that this is a handset.
    const shortEdge = Math.min(width, height);
    const longEdge = Math.max(width, height);
    const looksHandheld = shortEdge <= 500 && longEdge <= 1000;
    screenInfo.detected = looksHandheld ? "phone" : detectDevice(width);

    applyDevice();
  }

  /** Apply the detected device, the user's override, and the badge. */
  function applyDevice() {
    const body = document.body;
    let device = screenInfo.detected;
    let layout;

    if (viewMode === "phone") {
      device = "phone";
      layout = "thread";
    } else if (viewMode === "desktop") {
      // A phone forced to desktop gets the two-pane view; that is what the user asked for.
      device = "desktop";
      layout = "split";
    } else {
      layout = device === "phone" ? "thread" : "split";
      // A tablet in portrait is wide but not wide enough for two panes plus comfortable
      // reading, so it gets the single column at the narrow end of the tablet range.
      if (device === "tablet" && screenInfo.width <= 720) layout = "thread";
    }

    body.dataset.device = device;
    body.dataset.layout = layout;
    // Recorded separately from `device`, because a *forced* phone view on a wide browser has
    // to be told apart from a real phone: the page needs to narrow itself, not just switch to
    // the single-column layout.
    body.dataset.view = viewMode;

    // The thread container is hidden by an attribute in the markup, and the CSS switches it
    // on via `data-layout`. The attribute wins over the stylesheet, so the single-column view
    // has been empty since it was added — on a real phone as much as on a forced view. It is
    // cleared here, which is the only place that knows which layout is active.
    const thread = $("thread");
    if (thread) thread.hidden = layout !== "thread";

    for (const [id, mode] of [["view-auto", "auto"], ["view-phone", "phone"], ["view-desktop", "desktop"]]) {
      $(id)?.classList.toggle("on", viewMode === mode);
    }

    $("profile-badge").textContent =
      screenInfo.matched
        ? `${screenInfo.matched.name} · ${screenInfo.matched.width}×${screenInfo.matched.height}`
        : `${screenInfo.width}×${screenInfo.height} · unknown device`;
  }

  function setViewMode(mode) {
    viewMode = mode;
    // A deliberate choice clears any forced view in the URL, so the next reload does not
    // undo it.
    if (urlViewMode()) history.replaceState(null, "", location.pathname);
    try {
      localStorage.setItem(VIEW_MODE_KEY, mode);
    } catch { /* a private window with storage disabled: the choice just will not persist */ }
    applyDevice();
    // The two shapes render different DOM, so one of them has to be rebuilt.
    rebuildTranscripts();
    drawMessages();
    drawLive();
    if (state.follow) scrollToBottom();
  }

  /** Ask the known-device list what this screen probably is, for the badge and for support. */
  async function identifyDevice() {
    try {
      const match = await api.get(
        `/api/device?w=${screenInfo.width}&h=${screenInfo.height}` +
        `&mobile=${screenInfo.detected !== "desktop"}`);
      screenInfo.matched = match && match.matched ? match : null;
    } catch {
      screenInfo.matched = null;
    }
    applyDevice();
  }

  // ── Rendering ─────────────────────────────────────────────────────────────────────

  /** Rendered messages, keyed by id, so a turn is drawn once per container. */
  const rendered = new Map();
  const threadCopy = new Map();

  function seatIndexOf(message) {
    if (!state.snapshot) return -1;
    return state.snapshot.seats.findIndex(
      (s) => s.id === message.speakerID || s.name === message.speaker);
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
    const safe = String(text)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    return safe
      .split(/\\n{2,}/)
      .map((para) => `<p>${para.replace(/`([^`]+)`/g, "<code>$1</code>")}</p>`)
      .join("");
  }

  function labelFor(message) {
    switch (message.kind) {
      case "topic": return "MODERATOR · TOPIC";
      case "steering": return "MODERATOR";
      case "direction": return "RESEARCH MODERATOR · ASSIGNMENT";
      case "summary": return "CONDENSED EARLIER DISCUSSION";
      case "tool": return "TOOL";
      default: return String(message.speaker || "?").toUpperCase();
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
    return el;
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
  function buildPanes(seatCount) {
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
  function wirePaneControls() {
    for (const button of document.querySelectorAll(".name")) {
      // Guard against attaching twice to a pane that survived.
      if (button.dataset.wired === "1") continue;
      button.dataset.wired = "1";
      button.addEventListener("dblclick", () => startRename(button));
      button.addEventListener("keydown", (event) => {
        if (event.key === "Enter") { event.preventDefault(); startRename(button); }
      });
    }
  }

  function containers() {
    return [
      ...document.querySelectorAll(".transcript"),
      $("thread"),
    ].filter(Boolean);
  }

  function panes() {
    return [...document.querySelectorAll(".pane")].map((el) => ({
      root: el,
      transcript: el.querySelector(".transcript"),
    }));
  }

  /** Throw away the rendered copies, for when the shape of the DOM changes. */
  function rebuildTranscripts() {
    rendered.clear();
    threadCopy.clear();
    for (const container of containers()) container.textContent = "";
  }

  function drawMessages() {
    if (!state.snapshot) return;
    const inThread = document.body.dataset.layout === "thread";

    for (const message of state.snapshot.messages) {
      const seat = seatIndexOf(message);
      const shared = message.kind === "steering" || message.kind === "topic" ||
                     message.kind === "summary" || message.kind === "direction";

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
        empty.textContent = document.body.dataset.layout === "thread"
          ? "Nothing yet. Set a topic and press Start."
          : "Nothing yet.";
        container.append(empty);
      }
    }
  }

  /** Draw the reply currently being written, appending rather than rebuilding. */
  function drawLive() {
    if (!state.snapshot) return;
    const inThread = document.body.dataset.layout === "thread";
    const liveFor = (seatID) => state.snapshot.live.find((l) => l.seatID === seatID);

    if (inThread) {
      for (const seat of state.snapshot.seats) {
        const live = liveFor(seat.id);
        const existing = document.querySelector(`.msg.live[data-seat-id="${cssEscape(seat.id)}"]`);
        const active = live && (live.isGenerating || live.text || live.reasoning);
        if (!active) { existing?.remove(); continue; }
        const el = existing ?? createLiveElement(seat.id, seat.name, -1);
        $("thread").append(el);
        updateLiveElement(el, live);
      }
      if (state.follow) scrollToBottom();
      return;
    }

    for (const [index, pane] of panes().entries()) {
      const seat = state.snapshot.seats[index];
      if (!seat) continue;
      const live = liveFor(seat.id);
      const existing = pane.transcript.querySelector(".msg.live");
      const active = live && (live.isGenerating || live.text || live.reasoning);
      if (!active) { existing?.remove(); continue; }
      const el = existing ?? createLiveElement(seat.id, seat.name, index);
      pane.transcript.append(el);
      updateLiveElement(el, live);
    }
    if (state.follow) scrollToBottom();
  }

  function cssEscape(value) {
    return String(value).replace(/["\\\\]/g, "\\\\$&");
  }

  function createLiveElement(seatID, name, seatIndex) {
    const el = document.createElement("div");
    el.className = "msg live";
    el.dataset.seatId = seatID;
    if (seatIndex >= 0) el.dataset.seat = String(seatIndex);
    el.dataset.kind = "chat";
    el.innerHTML =
      `<div class="msg-head"><span class="msg-who">${name.toUpperCase()}</span>` +
      `<span class="msg-time">writing…</span></div>` +
      `<div class="msg-body caret"></div>`;
    return el;
  }

  function updateLiveElement(el, live) {
    const body = el.querySelector(".msg-body");
    // Only touch the DOM when the text actually grew.
    if (body.dataset.length !== String(live.text.length)) {
      body.innerHTML = bodyHTML(live.text || "");
      body.dataset.length = String(live.text.length);
    }
    body.classList.toggle("caret", live.isGenerating);
    el.querySelector(".msg-time").textContent = live.isGenerating ? "writing…" : "just now";

    // Thinking is shown only when asked for. On a phone it starts collapsed, because it is
    // long and the answer is what the reader came for.
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

  function scrollToBottom() {
    for (const container of containers()) container.scrollTop = container.scrollHeight;
  }

  // ── State → interface ─────────────────────────────────────────────────────────────

  function apply(next) {
    const first = state.snapshot === null;
    state.snapshot = next;
    // A seat count change replaces the panes, so it is handled before anything draws.
    if (buildPanes(next.seats.length)) {
      $("thread").textContent = "";
    }
    if (first) $("topic").value = next.topic || "";
    drawMessages();
    drawLive();
    drawControls();
    drawSeats();
    drawMode();
    drawAttachments();
    drawContext();
    drawResearch();
    if (first && next.messages.length && state.follow) scrollToBottom();
  }

  function drawControls() {
    const s = state.snapshot;
    const running = s.isRunning || s.status === "Paused";
    $("start").textContent = s.messages.length ? "Restart" : "Start";
    $("start").disabled = false;
    $("pause").disabled = !s.isRunning;
    $("pause").textContent = s.status === "Paused" ? "Resume" : "Pause";
    $("stop").disabled = !running;
    $("clear").disabled = s.messages.length === 0 && !running;
    $("save").disabled = s.messages.length === 0;
    $("condense").disabled = s.messages.length === 0;
    $("send").disabled = !running;
    $("topic").disabled = s.messages.length > 0;
    $("attach").disabled = !s.canAttach;
    $("files").disabled = !s.canAttach;

    const pill = $("status");
    pill.textContent = s.status;
    pill.className = "pill" +
      (s.isRunning ? " running" : s.status === "Paused" ? " paused" :
       String(s.status).startsWith("Failed") ? " failed" : "");
    $("counts").textContent = `${s.turnsCompleted} turn${s.turnsCompleted === 1 ? "" : "s"}`;
    if (s.error) toast(s.error);
  }

  /**
   * Show the persona library for the current mode and let one be chosen.
   *
   * A sheet rather than a dropdown: the entertainment cast is 36 characters and the research
   * library 19, and a native menu of that length is unusable on a phone. The sheet also lets
   * each persona carry its one-line description, which is what a moderator picks on.
   */
  async function openPersonaPicker(seatIndex) {
    const seat = state.snapshot && state.snapshot.seats[seatIndex];
    if (!seat) return;
    if (!state.snapshot.canAttach) {
      toast("Who is speaking is fixed once the conversation has started.");
      return;
    }

    let groups;
    try {
      groups = await api.get("/api/personas");
    } catch (error) {
      toast(error.message);
      return;
    }

    const sheet = document.createElement("div");
    sheet.className = "persona-sheet";
    sheet.innerHTML = `
      <div class="persona-sheet-inner">
        <div class="persona-sheet-head">
          <b>Who is ${escapeHTML(seat.name)}?</b>
          <div class="spacer"></div>
          <button class="small" data-close>Close</button>
        </div>
        <div class="persona-sheet-body"></div>
      </div>`;

    const body = sheet.querySelector(".persona-sheet-body");
    for (const group of groups) {
      // Only the active mode's library, plus the shared styles it also offers.
      if (group.mode !== state.snapshot.mode) continue;
      let lastCategory = null;
      for (const persona of group.personas) {
        if (persona.category !== lastCategory) {
          lastCategory = persona.category;
          const heading = document.createElement("div");
          heading.className = "persona-group";
          heading.textContent = persona.category || "Other";
          body.append(heading);
        }
        const item = document.createElement("button");
        item.className = "persona-item" + (persona.id === seat.personaID ? " on" : "");
        item.innerHTML =
          `<b>${escapeHTML(persona.emoji ? persona.emoji + " " : "")}${escapeHTML(persona.name)}</b>` +
          `<span>${escapeHTML(persona.summary)}</span>`;
        item.onclick = async () => {
          sheet.remove();
          await run(() => api.post("/api/seat", { seat: seat.id, personaID: persona.id }));
        };
        body.append(item);
      }
    }

    sheet.querySelector("[data-close]").onclick = () => sheet.remove();
    sheet.onclick = (event) => { if (event.target === sheet) sheet.remove(); };
    document.body.append(sheet);
  }

  function escapeHTML(text) {
    return String(text ?? "")
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  /** Reflect the room's mode in the switch. */
  function drawMode() {
    const mode = state.snapshot.mode;
    $("mode-entertainment").classList.toggle("on", mode === "entertainment");
    $("mode-research").classList.toggle("on", mode === "research");
    // The mode is fixed once the conversation starts, since the log was written against the
    // personas it began with.
    const locked = !state.snapshot.canAttach;
    $("mode-entertainment").disabled = locked;
    $("mode-research").disabled = locked;
  }

  function drawSeats() {
    const s = state.snapshot;
    for (const [index, pane] of panes().entries()) {
      const seat = s.seats[index];
      if (!seat) continue;
      const nameEl = pane.root.querySelector(".name");
      if (nameEl.contentEditable !== "true") nameEl.textContent = seat.name;
      pane.root.querySelector(".meta").textContent =
        `${seat.modelShortName} · ${seat.backend === "mlx" ? "MLX" : "API"} · ${seat.personaName}`;
      const picker = pane.root.querySelector(".persona-picker");
      if (picker) {
        picker.textContent = `${seat.personaEmoji ? seat.personaEmoji + " " : ""}${seat.personaName}`;
        picker.title = `${seat.personaName} — ${seat.personaSummary}`;
        picker.disabled = !s.canAttach;
        picker.dataset.personaSeat = String(index);
        picker.dataset.wiredPersona = picker.dataset.wiredPersona || "0";
        if (picker.dataset.wiredPersona !== "1") {
          picker.dataset.wiredPersona = "1";
          picker.addEventListener("click", () => openPersonaPicker(Number(picker.dataset.personaSeat)));
        }
      }

      const live = s.live.find((l) => l.seatID === seat.id);
      const busy = live && live.isGenerating;
      const stateEl = pane.root.querySelector(".state");
      stateEl.className = "state" + (busy ? " live" : "");
      stateEl.textContent = busy ? (live.activity || "thinking…") : "ready";
      pane.root.querySelector(".params").textContent =
        `temp ${seat.temperature.toFixed(2)} · top-p ${seat.topP.toFixed(2)} · top-k ${seat.topK} · ` +
        `min-p ${seat.minP.toFixed(1)} · pres ${Math.abs(seat.presencePenalty ?? 0).toFixed(1)} · ` +
        `max ${Math.round(seat.maxTokens / 1024)}k${seat.webSearch ? " · web" : ""}`;
    }
    $("persona-summary").textContent = s.seats.map((x) => `${x.name}: ${x.personaName}`).join("  ↔  ");

    const note = $("vision-note");
    if (s.imagesAllowed) {
      note.hidden = true;
    } else {
      const blind = s.seats.filter((x) => !x.vision).map((x) => x.name);
      note.hidden = false;
      note.textContent = `Images hidden — cannot see: ${blind.join(", ")}`;
    }
  }

  function drawAttachments() {
    const chips = $("chips");
    chips.textContent = "";
    const row = document.querySelector(".attach-row");
    // On a phone an empty attachment row is collapsed, so the chip list has to keep it open
    // once there is something in it.
    row?.classList.toggle("has-chips", state.snapshot.attachments.length > 0);

    for (const doc of state.snapshot.attachments) {
      const chip = document.createElement("span");
      chip.className = "chip";
      const name = document.createElement("b");
      name.textContent = doc.name;
      const detail = document.createElement("span");
      detail.textContent = `${doc.summary}${doc.wasTruncated ? " · shortened" : ""}`;
      const remove = document.createElement("button");
      remove.textContent = "✕";
      remove.title = `Remove ${doc.name}`;
      remove.setAttribute("aria-label", `Remove ${doc.name}`);
      remove.disabled = !state.snapshot.canAttach;
      remove.onclick = async () => {
        try { apply(await api.post("/api/attachments/remove", { value: doc.id })); }
        catch (error) { toast(error.message); }
      };
      chip.append(name, detail, remove);
      chips.append(chip);
    }
  }

  /** The research session, while there is one. */
  function drawResearch() {
    const s = state.snapshot;
    const bar = $("research-bar");
    const research = s.research;
    if (!research) {
      bar.hidden = true;
      // A finished session's report stays available even after the bar goes.
      if (!s.report) $("report-panel").hidden = true;
      return;
    }

    bar.hidden = false;
    $("research-depth").textContent = `${research.depth} · ${research.budgetSummary}`;
    $("research-progress").textContent = research.statusLine;
    // The budget is only settable before the run, so the controls disable with it.
    const locked = !s.canAttach;
    for (const [id, depth] of [["depth-quick", "quick"], ["depth-standard", "standard"],
                               ["depth-deep", "deep"]]) {
      const button = $(id);
      button.disabled = locked;
      button.classList.toggle("on", research.depth.toLowerCase() === depth);
    }

    if (s.report) showReport(s.report);
  }

  function showReport(report) {
    const panel = $("report-panel");
    panel.hidden = false;
    // Worth stating plainly: a report whose claims are unlabelled cannot be relied on, and
    // the reader has to be told rather than left to assume the labels are missing by mistake.
    const warnings = [];
    if (!report.isLabelled) warnings.push("no claim labels — treat everything as unverified");
    if (report.missingSections.length) {
      warnings.push(`not covered: ${report.missingSections.join(", ")}`);
    }
    $("report-meta").textContent =
      `${report.labelledClaims} labelled claims${warnings.length ? " · " + warnings.join(" · ") : ""}`;
    $("report-body").innerHTML = markdownToHTML(report.markdown);
  }

  /** Enough markdown for the report's own format: headings, list items, bold. */
  function markdownToHTML(markdown) {
    const escape = (t) => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    const lines = escape(markdown).split("\\n");
    let out = "";
    let inList = false;
    const closeList = () => { if (inList) { out += "</ul>"; inList = false; } };

    for (const raw of lines) {
      const line = raw.trimEnd();
      if (line.startsWith("## ")) { closeList(); out += `<h2>${line.slice(3)}</h2>`; continue; }
      if (line.startsWith("# ")) { closeList(); out += `<h1>${line.slice(2)}</h1>`; continue; }
      if (line.startsWith("- ") || line.startsWith("* ")) {
        if (!inList) { out += "<ul>"; inList = true; }
        out += `<li>${line.slice(2).replace(/\\*\\*(.+?)\\*\\*/g, "<strong>$1</strong>")}</li>`;
        continue;
      }
      closeList();
      if (line === "---") { out += "<hr>"; continue; }
      if (line.trim() === "") continue;
      out += `<p>${line.replace(/\\*\\*(.+?)\\*\\*/g, "<strong>$1</strong>")}</p>`;
    }
    closeList();
    return out;
  }

  function drawContext() {
    const s = state.snapshot;
    const pct = Math.round(s.contextFraction * 100);
    $("context").textContent =
      `ctx ${compact(s.contextTokens)}/${compact(s.contextWindow)} · ${pct}%`;
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

  // ── Commands ──────────────────────────────────────────────────────────────────────

  async function run(fn) {
    try {
      const next = await fn();
      if (next && next.seats) apply(next);
    } catch (error) {
      toast(error.message);
    }
  }

  // ── Kept conversations ───────────────────────────────────────────────────────────

  function stamp(iso) {
    const date = new Date(iso);
    if (Number.isNaN(date.getTime())) return "";
    const today = new Date();
    const sameDay = date.toDateString() === today.toDateString();
    return sameDay
      ? date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
      : date.toLocaleDateString([], { year: "numeric", month: "short", day: "numeric" });
  }

  async function refreshKept() {
    const body = $("kept-body");
    body.textContent = "";
    let list;
    try {
      list = await api.get("/api/conversations");
    } catch (error) {
      toast(error.message);
      return;
    }
    $("kept-meta").textContent = list.length
      ? `${list.length} kept`
      : "";

    if (!list.length) {
      const empty = document.createElement("div");
      empty.className = "kept-empty";
      empty.textContent =
        "Nothing kept yet. A conversation is kept as soon as it starts and stays after this window closes.";
      body.append(empty);
      return;
    }

    for (const item of list) {
      const row = document.createElement("div");
      row.className = "kept-row";

      const text = document.createElement("div");
      text.className = "kept-text";
      const topic = document.createElement("div");
      topic.className = "kept-topic";
      topic.textContent = item.topic || "Untitled";
      const sub = document.createElement("div");
      sub.className = "kept-sub";
      sub.textContent = item.summary || "";
      const meta = document.createElement("div");
      meta.className = "kept-meta";
      meta.textContent = `${item.replies} messages · ${stamp(item.updatedAt)}`;
      text.append(topic, sub, meta);

      const actions = document.createElement("div");
      actions.className = "kept-actions";

      const open = document.createElement("button");
      open.className = "small";
      open.textContent = "Open";
      open.disabled = Boolean(state.snapshot && state.snapshot.isRunning);
      if (open.disabled) open.title = "Stop the conversation before opening another one";
      open.onclick = async () => {
        await run(() => api.post("/api/conversations/load", { value: item.id }));
        $("kept-panel").hidden = true;
      };

      const remove = document.createElement("button");
      remove.className = "small";
      remove.textContent = "Delete";
      // A kept conversation is a file on disk, so this asks first: a mis-tap here destroys
      // work rather than hiding it.
      remove.onclick = async () => {
        if (!window.confirm(`Delete "${item.topic || "Untitled"}" from disk?`)) return;
        try {
          await api.post("/api/conversations/delete", { value: item.id });
        } catch (error) {
          toast(error.message);
        }
        await refreshKept();
      };

      actions.append(open, remove);
      row.append(text, actions);
      body.append(row);
    }
  }

  // ── Line-up and scenarios ────────────────────────────────────────────────────────

  function currentMode() {
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

  async function refreshLineup() {
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

  function wire() {
    $("start").onclick = () => run(() => api.post("/api/start"));
    $("pause").onclick = () => run(() =>
      api.post(state.snapshot && state.snapshot.status === "Paused" ? "/api/resume" : "/api/pause"));
    $("stop").onclick = () => run(() => api.post("/api/stop"));
    $("clear").onclick = () => run(() => api.post("/api/reset"));
    $("condense").onclick = () => run(() => api.post("/api/compact"));

    $("topic").addEventListener("change", () => {
      const value = $("topic").value.trim();
      if (!value || (state.snapshot && value === state.snapshot.topic)) return;
      run(() => api.post("/api/topic", { topic: value }));
    });

    $("thinking").onchange = () =>
      run(() => api.post("/api/settings", { showReasoning: $("thinking").checked }));

    $("send").onclick = send;
    $("message").addEventListener("keydown", (event) => {
      // Return sends on a desktop; on a phone the return key is how you start a new line, so
      // it must insert one.
      if (event.key === "Enter" && !event.shiftKey && document.body.dataset.device === "desktop") {
        event.preventDefault();
        send();
      }
    });

    $("save").onclick = save;
    $("attach").onclick = () => $("files").click();
    $("files").onchange = (event) => addFiles([...event.target.files]);

    $("mode-entertainment").onclick = () => setMode("entertainment");
    $("mode-research").onclick = () => setMode("research");
    $("depth-quick").onclick = () => setDepth("quick");
    $("depth-standard").onclick = () => setDepth("standard");
    $("depth-deep").onclick = () => setDepth("deep");
    $("report-close").onclick = () => { $("report-panel").hidden = true; };
    $("kept").onclick = () => {
      $("kept-panel").hidden = false;
      refreshKept();
    };
    $("kept-close").onclick = () => { $("kept-panel").hidden = true; };
    $("lineup").onclick = () => {
      $("lineup-panel").hidden = false;
      refreshLineup();
    };
    $("lineup-close").onclick = () => { $("lineup-panel").hidden = true; };
    $("lineup-surprise").onclick = async () => {
      // A scenario rather than a line-up: it sets the question as well, which is the point of
      // asking to be surprised.
      const mode = currentMode();
      let pool = [];
      try {
        pool = await api.get(`/api/scenarios?mode=${mode}`);
      } catch (error) {
        toast(error.message);
        return;
      }
      if (!pool.length) return;
      const pick = pool[Math.floor(Math.random() * pool.length)];
      await run(() => api.post("/api/scenario", { id: pick.id }));
      $("lineup-panel").hidden = true;
    };
    $("kept-refresh").onclick = refreshKept;
    $("kept-new").onclick = async () => {
      // The engine has already kept what is on screen, so this clears the view rather than
      // destroying anything — which is why it does not ask first.
      await run(() => api.post("/api/conversations/new"));
      await refreshKept();
      $("kept-panel").hidden = true;
    };
    $("report-download").onclick = () => {
      const report = state.snapshot && state.snapshot.report;
      if (!report) return;
      const blob = new Blob([report.markdown], { type: "text/markdown;charset=utf-8" });
      const a = document.createElement("a");
      a.href = URL.createObjectURL(blob);
      const slug = (report.question || "report").replace(/[^a-zA-Z0-9 ]/g, "").trim()
        .replace(/\\s+/g, "-").slice(0, 60);
      a.download = `ChatBots report ${slug}.md`;
      a.click();
      URL.revokeObjectURL(a.href);
    };

    $("view-auto").onclick = () => setViewMode("auto");
    $("view-phone").onclick = () => setViewMode("phone");
    $("view-desktop").onclick = () => setViewMode("desktop");

    wirePaneControls();

    for (const container of containers()) {
      container.addEventListener("scroll", () => {
        const distance = container.scrollHeight - container.scrollTop - container.clientHeight;
        state.follow = distance < 40;
      }, { passive: true });
    }

    window.addEventListener("keydown", (event) => {
      if (event.metaKey || event.ctrlKey) {
        if (event.key === "s") { event.preventDefault(); save(); }
        if (event.key === "Enter") { event.preventDefault(); $("start").click(); }
      }
    });

    // The viewport changes when a phone's address bar hides, when the keyboard opens, and on
    // rotation. All three change the usable height, so all three are re-measured.
    const remeasure = debounce(() => {
      measureViewport();
      identifyDevice();
    }, 120);
    window.addEventListener("resize", remeasure, { passive: true });
    window.addEventListener("orientationchange", remeasure, { passive: true });
    window.visualViewport?.addEventListener("resize", remeasure, { passive: true });

    // Keep the message box visible when the keyboard opens on a phone, which otherwise
    // pushes the footer under it.
    $("message").addEventListener("focus", () => {
      setTimeout(() => { if (state.follow) scrollToBottom(); }, 250);
    });
  }

  function debounce(fn, ms) {
    let timer = null;
    return (...args) => {
      clearTimeout(timer);
      timer = setTimeout(() => fn(...args), ms);
    };
  }

  async function setMode(mode) {
    await run(() => api.post("/api/mode", { value: mode }));
    // The line-ups and scenarios are per mode, so anything already drawn is now wrong.
    if (!$("lineup-panel").hidden) refreshLineup();
  }

  async function setDepth(depth) {
    await run(() => api.post("/api/research/budget", { value: depth }));
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
      if (event.key === "Enter") { event.preventDefault(); finish(true); }
      if (event.key === "Escape") { event.preventDefault(); finish(false); }
    };
    button.addEventListener("blur", onBlur);
    button.addEventListener("keydown", onKey);
  }

  async function addFiles(files) {
    if (!files.length) return;
    for (const file of files) {
      try {
        const buffer = await file.arrayBuffer();
        // Base64 rather than multipart: one code path on both sides, and these are documents
        // rather than media.
        let binary = "";
        const bytes = new Uint8Array(buffer);
        const chunk = 0x8000;
        for (let i = 0; i < bytes.length; i += chunk) {
          binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
        }
        apply(await api.post("/api/attachments", {
          filename: file.name,
          content: btoa(binary),
        }));
        toast(`Added ${file.name}`, true);
      } catch (error) {
        toast(`${file.name}: ${error.message}`);
      }
    }
    $("files").value = "";
  }

  function save() {
    if (!state.snapshot) return;
    const s = state.snapshot;
    const pad = (n) => String(n).padStart(2, "0");
    const stamp = (iso) => {
      const d = new Date(iso);
      return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
             `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
    };
    const now = new Date();
    let out = "ChatBots — conversation log\\n";
    out += `Topic: ${s.topic || "(none)"}\\n`;
    for (const seat of s.seats) out += `Participant: ${seat.name} (${seat.modelShortName})\\n`;
    out += `Exported: ${stamp(now)}\\n\\n${"-".repeat(72)}\\n`;
    for (const message of s.messages) {
      if (message.kind === "introduction") continue;
      out += `\\n[${stamp(message.timestamp)}] ${labelFor(message)}\\n`;
      out += message.text.split("\\n").map((line) => "    " + line).join("\\n") + "\\n";
    }
    const blob = new Blob([out], { type: "text/plain;charset=utf-8" });
    const a = document.createElement("a");
    const slug = (s.topic || "conversation").replace(/[^a-zA-Z0-9 ]/g, "").trim()
      .replace(/\\s+/g, "-").slice(0, 60);
    a.href = URL.createObjectURL(blob);
    a.download = `ChatBots ${slug} ${stamp(now).replace(/:/g, "-")}.txt`;
    a.click();
    URL.revokeObjectURL(a.href);
  }

  // ── Events ────────────────────────────────────────────────────────────────────────

  /**
   * Whether this load is a still capture.
   *
   * `?capture=1` skips the event stream. A headless screenshot never receives an update, so
   * the stream buys nothing, and an open connection is exactly what stops Chrome's virtual
   * time budget from expiring — it waits for the network to go quiet, and a server-sent feed
   * never does. The state fetched on load is everything a capture needs.
   */
  const isCapture = new URLSearchParams(location.search).has("capture");
  const isDiagnostic = new URLSearchParams(location.search).has("diag");

  /**
   * Report what this page measured about its own layout.
   *
   * Opt-in via `?diag=1`, and it exists because "is this laid out right on a 360-point
   * screen" is otherwise answered by reading a screenshot. It names the elements that are
   * wider than the viewport, which is the actual cause of a sideways-scrolling page; the
   * number alone would only say that something is wrong.
   */
  async function reportLayout() {
    if (!isDiagnostic) return;
    const root = document.documentElement;
    const viewport = Math.round(window.visualViewport?.width ?? window.innerWidth);
    const overflowing = [];
    for (const el of document.querySelectorAll("body *")) {
      const rect = el.getBoundingClientRect();
      if (rect.width > viewport + 1 || rect.right > viewport + 1) {
        const id = el.id ? `#${el.id}` : "";
        const cls = el.className && typeof el.className === "string"
          ? "." + el.className.trim().split(/\\s+/).slice(0, 2).join(".")
          : "";
        overflowing.push(`${el.tagName.toLowerCase()}${id}${cls}(${Math.round(rect.width)})`);
      }
    }
    // Worst first, and only the first few: a hundred entries help nobody.
    overflowing.sort((a, b) => {
      const num = (s) => Number(s.match(/\\((\\d+)\\)$/)?.[1] ?? 0);
      return num(b) - num(a);
    });
    try {
      await api.post("/api/client-report", {
        width: viewport,
        height: Math.round(window.visualViewport?.height ?? window.innerHeight),
        pixelRatio: window.devicePixelRatio,
        device: document.body.dataset.device,
        layout: document.body.dataset.layout,
        scrollWidth: root.scrollWidth,
        profile: screenInfo.matched ? screenInfo.matched.name : null,
        overflowing: overflowing.slice(0, 6),
      });
    } catch { /* a diagnostic that fails must not break the page */ }
  }

  function listen() {
    if (isCapture) return;
    const source = new EventSource("/api/events");
    source.addEventListener("snapshot", (event) => apply(JSON.parse(event.data)));
    source.addEventListener("turn", () => { /* the following snapshot carries it */ });
    source.onerror = () => toast("Lost the connection to the server — reconnecting…");
  }

  // ── Start ─────────────────────────────────────────────────────────────────────────
  // Measured before anything is drawn, so the first paint is already in the right shape.

  // A forced view is applied before the first measure so the first paint is already right.
  const forced = urlViewMode();
  if (forced) viewMode = forced;

  measureViewport();
  wire();
  api.get("/api/state").then(apply).catch((error) => toast(error.message));
  identifyDevice().then(reportLayout);
  listen();
})();

"""

}
