// ChatBots — the state and helpers every other page module shares.
//
// The client holds no conversation state of its own beyond what the server has told it, so there
// is one snapshot and one follow flag, and one copy of the small functions that read them. This
// is the leaf of the module graph and imports nothing, so no module can form a cycle through it.

export const $ = (id) => document.getElementById(id);

export const api = {
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

export const state = {
  /** The conversation, as last reported by the server. */
  snapshot: null,
  /**
   * Whether the transcript should follow new messages. Turned off when the reader scrolls
   * up, so reading back is not yanked away by an arriving reply.
   */
  follow: true,
};

// ── Reading the snapshot ───────────────────────────────────────────────────────────

/** Every element that holds a transcript: one per pane, plus the single-column thread. */
export function containers() {
  return [...document.querySelectorAll(".transcript"), $("thread")].filter(Boolean);
}

/** The panes, each with the transcript element it draws into. */
export function panes() {
  return [...document.querySelectorAll(".pane")].map((el) => ({
    root: el,
    transcript: el.querySelector(".transcript"),
  }));
}

export function seatIndexOf(message) {
  if (!state.snapshot) return -1;
  return state.snapshot.seats.findIndex(
    (s) => s.id === message.speakerID || s.name === message.speaker
  );
}

export function voteFor(turnID) {
  if (!state.snapshot || !state.snapshot.votes) return null;
  const found = state.snapshot.votes.find((v) => v.turnID === turnID);
  return found ? found.verdict : null;
}

// ── Text ───────────────────────────────────────────────────────────────────────────

export function formatTime(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const pad = (n) => String(n).padStart(2, "0");
  return (
    `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
    `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
  );
}

/** Escape first, then apply the little formatting worth having. */
export function bodyHTML(text) {
  const safe = String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  return safe
    .split(/\n{2,}/)
    .map((para) => `<p>${para.replace(/`([^`]+)`/g, "<code>$1</code>")}</p>`)
    .join("");
}

export function labelFor(message) {
  switch (message.kind) {
    case "topic":
      return String(message.speaker || "Moderator").toUpperCase() + " · TOPIC";
    case "steering":
      return String(message.speaker || "Moderator").toUpperCase();
    case "direction":
      return "RESEARCH MODERATOR · ASSIGNMENT";
    case "summary":
      return "CONDENSED EARLIER DISCUSSION";
    case "tool":
      return "TOOL";
    default:
      return String(message.speaker || "?").toUpperCase();
  }
}

export function escapeHTML(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// ── The chrome around the conversation ─────────────────────────────────────────────

let toastTimer = null;

export function toast(message, good = false) {
  const el = $("toast");
  el.textContent = message;
  el.className = "toast" + (good ? " good" : "");
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    el.hidden = true;
  }, 6000);
}

export function debounce(fn, ms) {
  let timer = null;
  return (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), ms);
  };
}
