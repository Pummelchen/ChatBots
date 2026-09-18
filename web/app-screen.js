// ChatBots — the screen profile and the user's view choice.
//
// The responsive part is deliberately *profile driven* rather than purely CSS media queries.
// A media query cannot express "the user asked for the desktop layout on a phone", and it
// cannot tell a 360-point Android entry model from a 360-point flagship — nor does it need
// to, which is the point: the layout branches on width, and the device profiles exist to
// verify that every width in use is covered. `data-device` carries the branch, `--vh` and
// `--vw` carry the measured viewport, and the safe-area insets come from CSS constants that
// only mean anything on a device with a notch.
//
// Everything that decides those lives here, so there is exactly one place that reads the live
// viewport and one place that writes the attributes CSS branches on.

import { $, api } from "./app-core.js";

const VIEW_MODE_KEY = "chatbots.viewMode";

/// Breakpoints, in CSS pixels. The tablet boundary is the one that matters: below it two
/// panes are too narrow to read, which is why a phone gets one column.
const PHONE_MAX = 719;
/// How wide a forced phone view is allowed to be, in CSS points. A 430-point column is a
/// large phone; wider and it stops reading as one.
const PHONE_VIEWPORT_MAX = 430;
const TABLET_MAX = 1023;

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

/** Adopt a forced view before the first measurement, so the first paint is already right. */
export function applyUrlViewMode() {
  const forced = urlViewMode();
  if (forced) viewMode = forced;
}

/** Measure the real visible viewport and publish it to CSS. */
export function measureViewport() {
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
  const composedWidth =
    viewMode === "phone" && width > PHONE_VIEWPORT_MAX ? PHONE_VIEWPORT_MAX : width;

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

  for (const [id, mode] of [
    ["view-auto", "auto"],
    ["view-phone", "phone"],
    ["view-desktop", "desktop"],
  ]) {
    $(id)?.classList.toggle("on", viewMode === mode);
  }

  // The stylesheet has said since it was written that this is "a debug label, shown only when
  // ?profile is in the URL" — and nothing ever unhid it, so the text was written into an element
  // that `[hidden] { display: none !important; }` keeps invisible. The condition the comment
  // describes is what is implemented here, rather than deleting a deliberate debug surface.
  const badge = $("profile-badge");
  badge.textContent = screenInfo.matched
    ? `${screenInfo.matched.name} · ${screenInfo.matched.width}×${screenInfo.matched.height}`
    : `${screenInfo.width}×${screenInfo.height} · unknown device`;
  badge.hidden = !profileRequested();
}

/// Whether the URL asks for the debug label.
function profileRequested() {
  return new URLSearchParams(location.search).has("profile");
}

/**
 * Record the mode the user chose and apply it.
 *
 * A deliberate choice clears any forced view in the URL, so the next reload does not undo it.
 * Redrawing the transcripts is the caller's job: the two shapes render different DOM, and the
 * modules that know how are the ones that own the drawing.
 */
export function chooseViewMode(mode) {
  viewMode = mode;
  if (urlViewMode()) history.replaceState(null, "", location.pathname);
  try {
    localStorage.setItem(VIEW_MODE_KEY, mode);
  } catch {
    /* a private window with storage disabled: the choice just will not persist */
  }
  applyDevice();
}

/** Ask the known-device list what this screen probably is, for the badge and for support. */
export async function identifyDevice() {
  try {
    const match = await api.get(
      `/api/device?w=${screenInfo.width}&h=${screenInfo.height}` +
        `&mobile=${screenInfo.detected !== "desktop"}`
    );
    screenInfo.matched = match && match.matched ? match : null;
  } catch {
    screenInfo.matched = null;
  }
  applyDevice();
}

// ── The layout diagnostic ──────────────────────────────────────────────────────────

const isDiagnostic = new URLSearchParams(location.search).has("diag");

/**
 * Report what this page measured about its own layout.
 *
 * Opt-in via `?diag=1`, and it exists because "is this laid out right on a 360-point
 * screen" is otherwise answered by reading a screenshot. It names the elements that are
 * wider than the viewport, which is the actual cause of a sideways-scrolling page; the
 * number alone would only say that something is wrong.
 *
 * It reports to the console rather than to the server. It used to POST to `/api/client-report`, a
 * route no version of the engine has ever had, so `?diag=1` measured the page and then threw the
 * measurement away into a 404 that its `catch` was written to hide. Whoever passes
 * `?diag=1` is already in the console, which is where the answer belongs; the alternative —
 * adding an unauthenticated write endpoint to serve a developer flag — is the surface this project
 * deliberately keeps closed.
 */
export function reportLayout() {
  if (!isDiagnostic) return;
  const root = document.documentElement;
  const viewport = Math.round(window.visualViewport?.width ?? window.innerWidth);
  const overflowing = [];
  for (const el of document.querySelectorAll("body *")) {
    const rect = el.getBoundingClientRect();
    if (rect.width > viewport + 1 || rect.right > viewport + 1) {
      const id = el.id ? `#${el.id}` : "";
      const cls =
        el.className && typeof el.className === "string"
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
  console.info("layout diagnostic", {
    width: viewport,
    height: Math.round(window.visualViewport?.height ?? window.innerHeight),
    pixelRatio: window.devicePixelRatio,
    device: document.body.dataset.device,
    layout: document.body.dataset.layout,
    scrollWidth: root.scrollWidth,
    profile: screenInfo.matched ? screenInfo.matched.name : null,
  });
  if (overflowing.length === 0) {
    console.info("no element is wider than the viewport");
  } else {
    console.info(
      "elements wider than the viewport, worst first:",
      overflowing.length,
      overflowing.slice(0, 6)
    );
  }
}
