// ChatBots — the web interface
//
// A thin client over the HTTP API. It holds no conversation state of its own beyond what it
// has been told: the server owns the conversation, so a reload, a second tab, or the SwiftUI
// app all see the same thing.
//
// This is the entry module. The state and the small helpers are in `app-core.js`, the screen
// profile in `app-screen.js`, the transcript in `app-transcript.js`, the rest of the panels in
// `app-controls.js`, the line-up in `app-lineup.js` and the commands in `app-commands.js`. What
// stays here is the reply being written, the snapshot dispatcher that drives the others, the
// event wiring and the start-up sequence.
//
// The modules form one cycle on purpose: `apply` and `run` live here and in `app-commands.js`
// respectively, and the drawing modules call them from their event handlers. Every binding that
// crosses the cycle is a hoisted function declaration, and nothing reads one while a module is
// still being evaluated, so the cycle is safe — the alternative was a global namespace object.

import { $, api, state, containers, panes, bodyHTML, toast, debounce } from "./app-core.js";
import {
  measureViewport,
  identifyDevice,
  applyUrlViewMode,
  chooseViewMode,
  reportLayout,
} from "./app-screen.js";
import {
  buildPanes,
  drawMessages,
  drawVotes,
  rebuildTranscripts,
  wirePaneControls,
} from "./app-transcript.js";
import {
  drawControls,
  drawSeats,
  drawMode,
  drawAttachments,
  drawContext,
  drawResearch,
  drawIdentity,
} from "./app-controls.js";
import { currentMode, refreshLineup } from "./app-lineup.js";
import {
  run,
  send,
  save,
  saveIdentity,
  setMode,
  setDepth,
  addFiles,
  refreshKept,
} from "./app-commands.js";

// ── The reply being written ────────────────────────────────────────────────────────
//
// The live entry is drawn in place rather than rebuilt, so it does not go through the
// rebuild-once maps the transcript keeps. `createLiveElement` and its neighbours are grouped
// here because they are the only drawing that mutates an element between turns.

const liveReply = (() => {
  function cssEscape(value) {
    return String(value).replace(/["\\]/g, "\\$&");
  }

  function createLiveElement(seatID, name, seatIndex) {
    const el = document.createElement("div");
    el.className = "msg live";
    el.dataset.seatId = seatID;
    if (seatIndex >= 0) el.dataset.seat = String(seatIndex);
    el.dataset.kind = "chat";
    // The scaffolding below is fixed markup, so it can be built as a string. The seat's name
    // cannot: it is whatever the moderator typed into the rename field, and every client
    // renders it, so a name like `<img src=x onerror=…>` would run in each open browser. It
    // is set as text. `.toUpperCase()` is presentation, not sanitisation — tag and attribute
    // names are case-insensitive. Every other render path in this file already escapes; this
    // was the one that did not.
    el.innerHTML =
      `<div class="msg-head"><span class="msg-who"></span>` +
      `<span class="msg-time">writing…</span></div>` +
      `<div class="msg-body caret"></div>`;
    el.querySelector(".msg-who").textContent = name.toUpperCase();
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
        if (!active) {
          existing?.remove();
          continue;
        }
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
      if (!active) {
        existing?.remove();
        continue;
      }
      const el = existing ?? createLiveElement(seat.id, seat.name, index);
      pane.transcript.append(el);
      updateLiveElement(el, live);
    }
    if (state.follow) scrollToBottom();
  }

  function scrollToBottom() {
    for (const container of containers()) container.scrollTop = container.scrollHeight;
  }

  return { createLiveElement, updateLiveElement, drawLive, scrollToBottom };
})();

// ── State → interface ─────────────────────────────────────────────────────────────

export function apply(next) {
  // One guard for every path a snapshot arrives by. `GET /api/state` at load races the first pushed
  // snapshot, and before this the older of the two could be applied last and stay on screen until the
  // next turn — the app-side client has refused stale snapshots since that guard was added.
  if (window.ChatBotsDeltas.isStale(next, state.snapshot)) return;
  const first = state.snapshot === null;
  state.snapshot = next;
  // A seat count change replaces the panes, so it is handled before anything draws.
  if (buildPanes(next.seats.length)) {
    $("thread").textContent = "";
  }
  if (first) $("topic").value = next.topic || "";
  drawMessages();
  drawVotes();
  liveReply.drawLive();
  drawControls();
  drawSeats();
  drawMode();
  drawAttachments();
  drawContext();
  drawResearch();
  drawIdentity();
  if (first && next.messages.length && state.follow) liveReply.scrollToBottom();
}

// ── The user's view choice ────────────────────────────────────────────────────────

function setViewMode(mode) {
  chooseViewMode(mode);
  // The two shapes render different DOM, so one of them has to be rebuilt.
  rebuildTranscripts();
  drawMessages();
  liveReply.drawLive();
  if (state.follow) liveReply.scrollToBottom();
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

function listen() {
  if (isCapture) return;
  const source = new EventSource("/api/events");
  source.addEventListener("snapshot", (event) => apply(JSON.parse(event.data)));
  source.addEventListener("turn", () => {
    /* the following snapshot carries it */
  });
  // The engine's own per-token events. Listening only for `snapshot` meant a reply appeared in one
  // piece when the turn ended, so a long research turn looked frozen while it was working while
  // the engine was publishing the words as it wrote them. `applyDelta` merges a fragment
  // into the live entries the renderer already draws from; nothing else about drawing changes.
  source.addEventListener("delta", (event) => {
    if (window.ChatBotsDeltas.applyDelta(state.snapshot, JSON.parse(event.data))) {
      liveReply.drawLive();
    }
  });
  source.onerror = () => toast("Lost the connection to the server — reconnecting…");
}

// Commit the topic, then start.
//
// The topic was posted only from the field's `change` event, and start was a separate request
// with no ordering between them: a topic typed and then started raced the start, the engine
// refused the late change ("the topic cannot be changed once the conversation has started"),
// and the room ran the previous topic. Awaiting the topic first makes the order the user meant.
async function startConversation() {
  const value = $("topic").value.trim();
  if (value && (!state.snapshot || value !== state.snapshot.topic)) {
    await run(() => api.post("/api/topic", { topic: value }));
  }
  await run(() => api.post("/api/start"));
}

function wire() {
  $("start").onclick = () => startConversation();
  $("pause").onclick = () =>
    run(() =>
      api.post(state.snapshot && state.snapshot.status === "Paused" ? "/api/resume" : "/api/pause")
    );
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
      // The window handler below also matches Cmd/Ctrl+Enter and presses Start, which restarts
      // and resets a running conversation — so one keystroke both sent the message and threw the
      // room away. Stopping propagation keeps the modifier chord on this handler.
      event.stopPropagation();
      send();
    }
  });

  $("votes-clear").onclick = () => run(() => api.post("/api/votes/clear"));
  // Applied on change rather than behind a Save button: it takes effect from the next turn,
  // so there is nothing to protect the user from and a button would only be a step to forget.
  $("mod-name").addEventListener("change", saveIdentity);
  $("mod-persona").addEventListener("change", saveIdentity);
  $("save").onclick = save;
  $("attach").onclick = () => $("files").click();
  $("files").onchange = (event) => addFiles([...event.target.files]);

  $("mode-entertainment").onclick = () => setMode("entertainment");
  $("mode-research").onclick = () => setMode("research");
  $("depth-quick").onclick = () => setDepth("quick");
  $("depth-standard").onclick = () => setDepth("standard");
  $("depth-deep").onclick = () => setDepth("deep");
  $("report-close").onclick = () => {
    $("report-panel").hidden = true;
  };
  $("kept").onclick = () => {
    $("kept-panel").hidden = false;
    refreshKept();
  };
  $("kept-close").onclick = () => {
    $("kept-panel").hidden = true;
  };
  $("lineup").onclick = () => {
    $("lineup-panel").hidden = false;
    refreshLineup();
  };
  $("lineup-close").onclick = () => {
    $("lineup-panel").hidden = true;
  };
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
    const slug = (report.question || "report")
      .replace(/[^a-zA-Z0-9 ]/g, "")
      .trim()
      .replace(/\s+/g, "-")
      .slice(0, 60);
    a.download = `ChatBots report ${slug}.md`;
    a.click();
    URL.revokeObjectURL(a.href);
  };

  $("view-auto").onclick = () => setViewMode("auto");
  $("view-phone").onclick = () => setViewMode("phone");
  $("view-desktop").onclick = () => setViewMode("desktop");

  wirePaneControls();

  // Scroll events do not bubble, and the panes are created after this runs, so this listens in
  // the capture phase on the document rather than attaching a listener to each container once
  // at start-up. Attaching then only ever saw #thread — which the split layout hides — so
  // `state.follow` was never set to false and every streaming delta pulled the pane to the
  // bottom, making it impossible to read back while a reply arrived.
  document.addEventListener(
    "scroll",
    (event) => {
      const container = event.target;
      const isTranscript =
        container === $("thread") ||
        (container.classList && container.classList.contains("transcript"));
      if (!isTranscript) return;
      const distance = container.scrollHeight - container.scrollTop - container.clientHeight;
      state.follow = distance < 40;
    },
    { capture: true, passive: true }
  );

  window.addEventListener("keydown", (event) => {
    if (event.metaKey || event.ctrlKey) {
      if (event.key === "s") {
        event.preventDefault();
        save();
      }
      if (event.key === "Enter") {
        event.preventDefault();
        $("start").click();
      }
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
    setTimeout(() => {
      if (state.follow) liveReply.scrollToBottom();
    }, 250);
  });
}

// ── Start ─────────────────────────────────────────────────────────────────────────
// Measured before anything is drawn, so the first paint is already in the right shape.

applyUrlViewMode();
measureViewport();
wire();
api
  .get("/api/state")
  .then(apply)
  .catch((error) => toast(error.message));
identifyDevice().then(() => reportLayout());
listen();
