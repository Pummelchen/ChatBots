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

    root.style.setProperty("--vw", width + "px");
    root.style.setProperty("--vh", height + "px");

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
      .split(/\n{2,}/)
      .map((para) => `<p>${para.replace(/`([^`]+)`/g, "<code>$1</code>")}</p>`)
      .join("");
  }

  function labelFor(message) {
    switch (message.kind) {
      case "topic": return "MODERATOR · TOPIC";
      case "steering": return "MODERATOR";
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
                     message.kind === "summary";

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
    return String(value).replace(/["\\]/g, "\\$&");
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
    const lines = escape(markdown).split("\n");
    let out = "";
    let inList = false;
    const closeList = () => { if (inList) { out += "</ul>"; inList = false; } };

    for (const raw of lines) {
      const line = raw.trimEnd();
      if (line.startsWith("## ")) { closeList(); out += `<h2>${line.slice(3)}</h2>`; continue; }
      if (line.startsWith("# ")) { closeList(); out += `<h1>${line.slice(2)}</h1>`; continue; }
      if (line.startsWith("- ") || line.startsWith("* ")) {
        if (!inList) { out += "<ul>"; inList = true; }
        out += `<li>${line.slice(2).replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")}</li>`;
        continue;
      }
      closeList();
      if (line === "---") { out += "<hr>"; continue; }
      if (line.trim() === "") continue;
      out += `<p>${line.replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")}</p>`;
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
    $("report-download").onclick = () => {
      const report = state.snapshot && state.snapshot.report;
      if (!report) return;
      const blob = new Blob([report.markdown], { type: "text/markdown;charset=utf-8" });
      const a = document.createElement("a");
      a.href = URL.createObjectURL(blob);
      const slug = (report.question || "report").replace(/[^a-zA-Z0-9 ]/g, "").trim()
        .replace(/\s+/g, "-").slice(0, 60);
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
    let out = "ChatBots — conversation log\n";
    out += `Topic: ${s.topic || "(none)"}\n`;
    for (const seat of s.seats) out += `Participant: ${seat.name} (${seat.modelShortName})\n`;
    out += `Exported: ${stamp(now)}\n\n${"-".repeat(72)}\n`;
    for (const message of s.messages) {
      if (message.kind === "introduction") continue;
      out += `\n[${stamp(message.timestamp)}] ${labelFor(message)}\n`;
      out += message.text.split("\n").map((line) => "    " + line).join("\n") + "\n";
    }
    const blob = new Blob([out], { type: "text/plain;charset=utf-8" });
    const a = document.createElement("a");
    const slug = (s.topic || "conversation").replace(/[^a-zA-Z0-9 ]/g, "").trim()
      .replace(/\s+/g, "-").slice(0, 60);
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
          ? "." + el.className.trim().split(/\s+/).slice(0, 2).join(".")
          : "";
        overflowing.push(`${el.tagName.toLowerCase()}${id}${cls}(${Math.round(rect.width)})`);
      }
    }
    // Worst first, and only the first few: a hundred entries help nobody.
    overflowing.sort((a, b) => {
      const num = (s) => Number(s.match(/\((\d+)\)$/)?.[1] ?? 0);
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
