// ChatBots — the commands the page sends, and the kept-conversation list.
//
// One place for everything that posts to the engine and for the moderator's own identity. `run`
// is the only path a command takes, so there is one place that decides what a refusal or an
// unreachable engine means, and one place that answers whether the engine took the command.

import { $, api, state, labelFor, toast } from "./app-core.js";
import { apply } from "./app.js";
import { refreshLineup } from "./app-lineup.js";

// Run one command and answer whether the engine took it.
//
// The answer matters to `send` below and to nothing else: a command that is refused, or an engine
// that cannot be reached, arrives here as a thrown error, and the caller that has to decide what a
// failure means needs to know it happened.
export async function run(fn) {
  try {
    const next = await fn();
    if (next && next.seats) apply(next);
    return true;
  } catch (error) {
    toast(error.message);
    return false;
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

export async function refreshKept() {
  const body = $("kept-body");
  body.textContent = "";
  let list;
  try {
    list = await api.get("/api/conversations");
  } catch (error) {
    toast(error.message);
    return;
  }
  $("kept-meta").textContent = list.length ? `${list.length} kept` : "";

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

    const link = document.createElement("button");
    link.className = "small";
    link.textContent = "Link";
    link.title = "Copy a read-only link to this conversation";
    link.onclick = async () => {
      // This page's own origin, not the engine's. The engine reports its loopback address, which
      // is right for a browser on the Mac running it and unreachable from a phone; the
      // origin is the address this page is actually being read at, which is what the person
      // receiving the link needs. The snapshot's value is the fallback for an origin that is not
      // a usable base (`file:` pages report "null").
      const origin = window.location.origin;
      const base =
        origin && origin !== "null" ? origin : state.snapshot && state.snapshot.shareBase;
      const url = `${base}/s/${item.id}`;
      try {
        await navigator.clipboard.writeText(url);
        toast("Link copied.");
      } catch {
        // Clipboard access needs a secure context; showing the link is the honest fallback
        // rather than reporting a copy that did not happen.
        window.prompt("Copy this link:", url);
      }
    };

    actions.append(open, link, remove);
    row.append(text, actions);
    body.append(row);
  }
}

// ── Who the moderator is ─────────────────────────────────────────────────────────

export function saveIdentity() {
  run(() =>
    api.post("/api/moderator", {
      name: $("mod-name").value.trim() || "Moderator",
      personaID: $("mod-persona").value,
    })
  );
}

// ── Mode and the research budget ─────────────────────────────────────────────────

export async function setMode(mode) {
  await run(() => api.post("/api/mode", { value: mode }));
  // The line-ups and scenarios are per mode, so anything already drawn is now wrong.
  if (!$("lineup-panel").hidden) refreshLineup();
}

export async function setDepth(depth) {
  await run(() => api.post("/api/research/budget", { value: depth }));
}

// ── The message box and the file picker ──────────────────────────────────────────

// Whether a send is in flight.
//
// The box used to be emptied *before* the request, which is also what stopped a second Return from
// posting the same text twice. Emptying it afterwards — so a refused send keeps what was typed —
// needs that guard to be explicit.
let sending = false;

export async function send() {
  const box = $("message");
  const text = box.value.trim();
  if (!text || sending) return;
  sending = true;
  try {
    // The box is emptied only once the engine has taken the message. Emptying it first meant a
    // send the engine refused, or one that never left the page because the engine could not be
    // reached, silently discarded what the moderator had typed.
    if (!(await run(() => api.post("/api/message", { text })))) return;
    // Only the text that was sent: anything typed while the request was in flight stays.
    if (box.value.trim() === text) {
      box.value = "";
      autosize(box);
    }
  } finally {
    sending = false;
  }
}

function autosize(box) {
  box.style.height = "auto";
  box.style.height = Math.min(box.scrollHeight, 96) + "px";
}

export async function addFiles(files) {
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
      apply(
        await api.post("/api/attachments", {
          filename: file.name,
          content: btoa(binary),
        })
      );
      toast(`Added ${file.name}`, true);
    } catch (error) {
      toast(`${file.name}: ${error.message}`);
    }
  }
  $("files").value = "";
}

// ── The conversation log ─────────────────────────────────────────────────────────

export function save() {
  if (!state.snapshot) return;
  const s = state.snapshot;
  const pad = (n) => String(n).padStart(2, "0");
  const stamp = (iso) => {
    const d = new Date(iso);
    return (
      `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
      `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
    );
  };
  const now = new Date();
  let out = "ChatBots — conversation log\n";
  out += `Topic: ${s.topic || "(none)"}\n`;
  for (const seat of s.seats) out += `Participant: ${seat.name} (${seat.modelShortName})\n`;
  out += `Exported: ${stamp(now)}\n\n${"-".repeat(72)}\n`;
  for (const message of s.messages) {
    if (message.kind === "introduction") continue;
    out += `\n[${stamp(message.timestamp)}] ${labelFor(message)}\n`;
    out +=
      message.text
        .split("\n")
        .map((line) => "    " + line)
        .join("\n") + "\n";
  }
  const blob = new Blob([out], { type: "text/plain;charset=utf-8" });
  const a = document.createElement("a");
  const slug = (s.topic || "conversation")
    .replace(/[^a-zA-Z0-9 ]/g, "")
    .trim()
    .replace(/\s+/g, "-")
    .slice(0, 60);
  a.href = URL.createObjectURL(blob);
  a.download = `ChatBots ${slug} ${stamp(now).replace(/:/g, "-")}.txt`;
  a.click();
  URL.revokeObjectURL(a.href);
}
