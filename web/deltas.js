// ChatBots — what the page does with the state the engine sends it.
//
// Two pure rules, both about incoming state rather than about drawing: how a per-token fragment is
// folded into the live entries (`applyDelta`), and which of two snapshots is newer (`isStale`). They
// live here rather than in `app.js` because they are the parts that are easy to get wrong and
// impossible to run inside a page — `tools/check-web-deltas.js` exercises both in Node.
//
// The engine publishes each fragment as it is produced, as `delta` on the event stream, and the
// server sends a whole snapshot once per turn. The page draws the reply being written from
// `state.snapshot.live`, so streaming a reply means merging those fragments into that array as they
// arrive — not adding a second rendering path beside the one that draws a finished turn.
//
// No DOM in this file, which is the point: the merge is the part that is easy to get wrong (a turn
// that starts must clear what the previous turn left, reasoning accumulates separately from the
// answer, an unknown agent must not invent a seat), and keeping it here lets
// `tools/check-web-deltas.js` run it in Node against those cases.

(function (global) {
  "use strict";

  /** A live entry for a seat that has none yet, with every field the renderer reads. */
  function emptyLive(seatID) {
    return {
      seatID: seatID,
      isGenerating: true,
      text: "",
      reasoning: "",
      activity: null,
      toolLog: [],
      stats: null,
    };
  }

  /**
   * Merge one delta into `snapshot`, in place.
   *
   * Returns whether the snapshot changed in a way the page draws. `false` means the delta was
   * ignored — an unknown `kind`, or an agent that is not one of the seats — and the caller can then
   * skip a redraw.
   */
  function applyDelta(snapshot, delta) {
    if (!snapshot || !delta || !delta.agentID) return false;
    const seats = snapshot.seats || [];
    if (!seats.some((seat) => seat.id === delta.agentID)) return false;

    if (!snapshot.live) snapshot.live = [];
    let live = snapshot.live.find((entry) => entry.seatID === delta.agentID);
    if (!live) {
      live = emptyLive(delta.agentID);
      snapshot.live.push(live);
    }

    if (delta.kind === "started") {
      // A turn is beginning for this seat: whatever is here belongs to the previous one, and the
      // snapshot that would have cleared it may not have arrived yet.
      live.text = "";
      live.reasoning = "";
      live.isGenerating = true;
    } else if (delta.kind === "token") {
      live.text = (live.text || "") + (delta.text || "");
      live.isGenerating = true;
    } else if (delta.kind === "reasoning") {
      live.reasoning = (live.reasoning || "") + (delta.text || "");
      live.isGenerating = true;
    } else {
      // `tool` and any kind added later are carried by the snapshot that follows the turn.
      return false;
    }
    return true;
  }

  /**
   * Whether `next` was produced before `current`, and must therefore not replace it.
   *
   * The engine stamps every snapshot with a monotonic revision, which orders two produced inside the
   * same second — its wall clock cannot, because `serverTime` is ISO-8601 to the second — and keeps
   * ordering them when the clock moves backwards. The app has carried this guard since it was introduced; the page
   * applied whatever arrived last, so a `GET /api/state` racing the first pushed snapshot could put
   * the older one on screen and leave it there until the next turn.
   *
   * A snapshot from an engine that predates the field carries no revision, and then the clock is the
   * only ordering available — the same fallback `APISnapshot.isOlder(than:)` makes, so the two front
   * ends cannot disagree about which state is newer.
   */
  function isStale(next, current) {
    if (!current) return false;
    const nextRevision = next && next.revision;
    const currentRevision = current.revision;
    if (typeof nextRevision === "number" && typeof currentRevision === "number") {
      return nextRevision < currentRevision;
    }
    const nextTime = Date.parse((next && next.serverTime) || "");
    const currentTime = Date.parse(current.serverTime || "");
    if (Number.isNaN(nextTime) || Number.isNaN(currentTime)) return false;
    return nextTime < currentTime;
  }

  const api = { applyDelta: applyDelta, emptyLive: emptyLive, isStale: isStale };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else global.ChatBotsDeltas = api;
})(typeof window !== "undefined" ? window : globalThis);
