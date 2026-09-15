// ChatBots — folding the engine's per-token events into the state the page draws.
//
// The engine publishes each fragment as it is produced, as `delta` on the event stream, and the
// server sends a whole snapshot once per turn. The page draws the reply being written from
// `state.snapshot.live`, so streaming a reply means merging those fragments into that array as they
// arrive — not adding a second rendering path beside the one that draws a finished turn.
//
// No DOM in this file, which is the point: the merge is the part that is easy to get wrong (a turn
// that starts must clear what the previous turn left, reasoning accumulates separately from the
// answer, an unknown agent must not invent a seat), and keeping it here lets
// `tools/check-web-deltas.js` run it in Node against those cases (A165).

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

  const api = { applyDelta: applyDelta, emptyLive: emptyLive };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else global.ChatBotsDeltas = api;
})(typeof window !== "undefined" ? window : globalThis);
