// ChatBots — the controls and panels drawn from a snapshot.
//
// Everything a snapshot turns into outside the transcript: the transport buttons, the status
// row, the seat headers and their persona and checkpoint pickers, the attachments, the research
// bar, the report, the context meter and the moderator's identity. Each function reads
// `state.snapshot` and writes one region, so one change to the state redraws only what moved.

import { $, api, state, panes, escapeHTML, toast } from "./app-core.js";
import { run } from "./app-commands.js";
import { apply } from "./app.js";

export function drawControls() {
  const s = state.snapshot;
  const running = s.isRunning || s.status === "Paused";
  $("start").textContent = s.messages.length ? "Restart" : "Start";
  $("start").disabled = false;
  $("pause").disabled = !s.isRunning;
  $("pause").textContent = s.status === "Paused" ? "Resume" : "Pause";
  $("stop").disabled = !running;
  $("clear").disabled = s.messages.length === 0 && !running;
  $("save").disabled = s.messages.length === 0;
  drawAudience();
  $("votes-clear").hidden = !s.votes || s.votes.length === 0;
  $("condense").disabled = s.messages.length === 0;
  $("send").disabled = !running;
  $("topic").disabled = s.messages.length > 0;
  $("attach").disabled = !s.canAttach;
  $("files").disabled = !s.canAttach;

  const pill = $("status");
  pill.textContent = s.status;
  pill.className =
    "pill" +
    (s.isRunning
      ? " running"
      : s.status === "Paused"
        ? " paused"
        : String(s.status).startsWith("Failed")
          ? " failed"
          : "");
  $("counts").textContent = `${s.turnsCompleted} turn${s.turnsCompleted === 1 ? "" : "s"}`;
  if (s.error) toast(s.error);
}

/** The scorecard, in the status row. */
function drawAudience() {
  const el = $("audience");
  const entries = (state.snapshot && state.snapshot.audience) || [];
  if (!entries.length) {
    el.textContent = "";
    el.hidden = true;
    return;
  }
  el.hidden = false;
  el.textContent =
    "Audience: " +
    entries.map((entry) => `${entry.name} ${entry.score > 0 ? "+" : ""}${entry.score}`).join(" · ");
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
  sheet.onclick = (event) => {
    if (event.target === sheet) sheet.remove();
  };
  document.body.append(sheet);
}

/** Reflect the room's mode in the switch. */
export function drawMode() {
  const mode = state.snapshot.mode;
  $("mode-entertainment").classList.toggle("on", mode === "entertainment");
  $("mode-research").classList.toggle("on", mode === "research");
  // The mode is fixed once the conversation starts, since the log was written against the
  // personas it began with.
  const locked = !state.snapshot.canAttach;
  $("mode-entertainment").disabled = locked;
  $("mode-research").disabled = locked;
}

export function drawSeats() {
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
        picker.addEventListener("click", () =>
          openPersonaPicker(Number(picker.dataset.personaSeat))
        );
      }
    }

    const modelPicker = pane.root.querySelector(".model-picker");
    if (modelPicker) {
      // The catalogue comes from the engine, so the page offers exactly what the app's own picker
      // does. An engine too old to send one leaves the select empty rather than showing a list the
      // page invented.
      const models = s.availableModels || [];
      if (modelPicker.dataset.filledModels !== String(models.length)) {
        modelPicker.textContent = "";
        for (const model of models) {
          const option = document.createElement("option");
          option.value = model.id;
          option.textContent = model.sizeLabel ? `${model.name} · ${model.sizeLabel}` : model.name;
          option.title = model.summary;
          modelPicker.append(option);
        }
        modelPicker.dataset.filledModels = String(models.length);
      }
      modelPicker.value = seat.model;
      // Fixed once the conversation has started, for the reason the engine refuses it: the seat's
      // engine is the one a turn in flight is generating on.
      modelPicker.disabled = !s.canAttach;
      modelPicker.title = models.find((m) => m.id === seat.model)?.summary || seat.model;
      if (modelPicker.dataset.wiredModel !== "1") {
        modelPicker.dataset.wiredModel = "1";
        modelPicker.addEventListener("change", () =>
          run(() => api.post("/api/seat", { seat: seat.id, modelID: modelPicker.value }))
        );
      }
    }

    const live = s.live.find((l) => l.seatID === seat.id);
    const busy = live && live.isGenerating;
    const stateEl = pane.root.querySelector(".state");
    stateEl.className = "state" + (busy ? " live" : "");
    stateEl.textContent = busy ? live.activity || "thinking…" : "ready";
    pane.root.querySelector(".params").textContent =
      `temp ${seat.temperature.toFixed(2)} · top-p ${seat.topP.toFixed(2)} · top-k ${seat.topK} · ` +
      `min-p ${seat.minP.toFixed(1)} · pres ${Math.abs(seat.presencePenalty ?? 0).toFixed(1)} · ` +
      `max ${Math.round(seat.maxTokens / 1024)}k${seat.webSearch ? " · web" : ""}`;
  }
  $("persona-summary").textContent = s.seats
    .map((x) => `${x.name}: ${x.personaName}`)
    .join("  ↔  ");

  const note = $("vision-note");
  if (s.imagesAllowed) {
    note.hidden = true;
  } else {
    const blind = s.seats.filter((x) => !x.vision).map((x) => x.name);
    note.hidden = false;
    note.textContent = `Images hidden — cannot see: ${blind.join(", ")}`;
  }
}

export function drawAttachments() {
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
      try {
        apply(await api.post("/api/attachments/remove", { value: doc.id }));
      } catch (error) {
        toast(error.message);
      }
    };
    chip.append(name, detail, remove);
    chips.append(chip);
  }
}

/** The research session, while there is one. */
export function drawResearch() {
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
  for (const [id, depth] of [
    ["depth-quick", "quick"],
    ["depth-standard", "standard"],
    ["depth-deep", "deep"],
  ]) {
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
  const closeList = () => {
    if (inList) {
      out += "</ul>";
      inList = false;
    }
  };

  for (const raw of lines) {
    const line = raw.trimEnd();
    if (line.startsWith("## ")) {
      closeList();
      out += `<h2>${line.slice(3)}</h2>`;
      continue;
    }
    if (line.startsWith("# ")) {
      closeList();
      out += `<h1>${line.slice(2)}</h1>`;
      continue;
    }
    if (line.startsWith("- ") || line.startsWith("* ")) {
      if (!inList) {
        out += "<ul>";
        inList = true;
      }
      out += `<li>${line.slice(2).replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")}</li>`;
      continue;
    }
    closeList();
    if (line === "---") {
      out += "<hr>";
      continue;
    }
    if (line.trim() === "") continue;
    out += `<p>${line.replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")}</p>`;
  }
  closeList();
  return out;
}

export function drawContext() {
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

/**
 * Fill the moderator's identity controls from the state.
 *
 * Only while the panel is closed or the field is untouched: the engine is the source of truth,
 * but overwriting a half-typed name on the next poll would make the field unusable.
 */
export function drawIdentity() {
  const s = state.snapshot;
  if (!s) return;

  const select = $("mod-persona");
  if (select.options.length !== s.availablePersonas.length + 1) {
    select.textContent = "";
    const neutral = document.createElement("option");
    neutral.value = "neutral";
    neutral.textContent = "Neutral — no style imposed";
    select.append(neutral);
    for (const persona of s.availablePersonas) {
      const option = document.createElement("option");
      option.value = persona.id;
      option.textContent = `${persona.emoji} ${persona.name}`;
      select.append(option);
    }
  }
  // The engine reports the display name; the select needs the identifier.
  const style = s.availablePersonas.find((p) => p.name === s.moderatorPersona);
  const identifier = s.moderatorPersona.startsWith("Neutral")
    ? "neutral"
    : style
      ? style.id
      : "neutral";
  if (document.activeElement !== select) select.value = identifier;

  if (document.activeElement !== $("mod-name")) {
    $("mod-name").value = s.moderatorName || "";
  }
  const persona = s.moderatorPersona.startsWith("Neutral") ? "" : ` · ${s.moderatorPersona}`;
  $("you-summary").textContent = `You: ${s.moderatorName || "Moderator"}${persona}`;
}
