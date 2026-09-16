// ChatBots — the audience's verdict, as a rule rather than a DOM handler.
//
// Two pure functions, both about a vote rather than about drawing: which verdict a click means
// (`nextVerdict`), and whether a button is the one on record (`isOn`). They live here rather than in
// `app.js` because `tools/check-web-votes.js` can run them in Node — and because the rule appeared twice,
// once when a row was built and once when the marks were redrawn, which is how the two came to disagree.
//
// The engine's contract is that a vote with a verdict records it and a vote with `null` withdraws it, so
// clicking the verdict already cast means "take it back". Casting its opposite instead would put a
// judgement in the record that nobody made, which is the reason the withdrawal is worth having.
//
// A160 is why this file exists: the row captured the verdict it was built with, and a turn is drawn once —
// its marks are redrawn in place — so the captured value was normally "none", and clicking the cast verdict
// re-cast it instead of withdrawing it.

(function (global) {
  "use strict";

  /** The verdict a click on `clicked` means, given the verdict `current` on record. */
  function nextVerdict(current, clicked) {
    return current === clicked ? null : clicked;
  }

  /** Whether `verdict` is the one on record. */
  function isOn(current, verdict) {
    return current === verdict;
  }

  const api = { nextVerdict: nextVerdict, isOn: isOn };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else global.ChatBotsVotes = api;
})(typeof window !== "undefined" ? window : globalThis);
