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
      .split(/\n{2,}/)
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
    let out = "ChatBots — conversation log\n";
    out += `Topic: ${state.topic || "(none)"}\n`;
    for (const seat of state.seats) out += `Participant: ${seat.name} (${seat.modelShortName})\n`;
    out += `Exported: ${stamp(now)}\n\n${"-".repeat(72)}\n`;
    for (const message of state.messages) {
      if (message.kind === "introduction") continue;
      const who = labelFor(message, seatIndexOf(message));
      out += `\n[${stamp(message.timestamp)}] ${who}\n`;
      out += message.text.split("\n").map((line) => "    " + line).join("\n") + "\n";
    }
    const blob = new Blob([out], { type: "text/plain;charset=utf-8" });
    const a = document.createElement("a");
    const slug = (state.topic || "conversation").replace(/[^a-zA-Z0-9 ]/g, "").trim()
      .replace(/\s+/g, "-").slice(0, 60);
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
