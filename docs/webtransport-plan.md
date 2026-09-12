# WebTransport Migration — Implementation Plan

**Status: implemented.** All 21 tasks landed on `main`; this file is kept as the record of what
was planned and why, so it describes the intent at the time rather than the current state. The
test count below (372) is the figure when the plan was written, not today's. For what is still
open, see the wiki's [What is left to do](https://github.com/Pummelchen/ChatBots/wiki/What-is-left-to-do).

Goal: the desktop app talks to the engine over WebTransport instead of holding one. Caddy
keeps serving the website over HTTP. Both front ends reach one engine.

Architecture after this work:

```
   browser ──HTTP──▶ Caddy :7788 ──HTTP──▶ ┌──────────────────┐
                                           │  EngineService   │  ← one dispatch, no
   desktop app ──WebTransport──QUIC──▶     │  (engine + API)  │    transport knowledge
                                           └──────────────────┘
```

---

## A. Foundations

**1. Extract `EngineService` from `APIServer`.**
The request→reply logic currently lives inside the HTTP server. Move it into a type that
knows nothing about HTTP: it takes an `EngineRequest` and returns an `EngineReply`, or
returns `nil` for "no reply". Both transports then call the same dispatch, so a command
cannot work over one channel and not the other.

**2. Route HTTP through `EngineService`.**
Rewrite the HTTP routes as translations to `EngineRequest`, so HTTP becomes a thin adapter.
Every existing behaviour — including the 409s that refuse a locked topic — must survive.

**3. Test `EngineService` directly.**
Pure tests: each request maps to the right engine call, refusals are refusals, and nothing
throws. This replaces route-level testing with something faster and transport-free.

## B. WebTransport server

**4. Certificate management.**
Use `.developmentSelfSigned`, persist the identity so the fingerprint is stable across
restarts (a client that pinned yesterday must still connect today), and expose the SHA-256
fingerprint for the client to pin. Persist to `.run/` so it is not committed.

**5. `WebTransportEngineServer`.**
Accept sessions in a loop, one task per session, with a bounded number of concurrent
sessions and clean shutdown. Must not block the engine's main actor.

**6. Request channel.**
One bidirectional stream per session: read length-framed `EngineRequest`, dispatch through
`EngineService`, write the length-framed `EngineReply`. A refused command replies; it does
not close the session.

**7. Event channel.**
A second stream per session carrying newline-delimited `EngineEvent`. State after every
change, output deltas as they are produced. Slow clients must not stall the engine: each
session gets its own buffer and a client that cannot keep up is dropped rather than allowed
to back-pressure the model.

**8. Server tests.**
Handshake, a full request/reply round trip, a refusal, event delivery, two clients at once,
and a client that disconnects mid-stream.

## C. Desktop app

**9. `ConversationClient` over WebTransport.**
Connect, pin the fingerprint, open both channels, decode replies and events, reconnect with
backoff. Adopt the snapshot as observable state.

**10. Engine supervisor.**
The app starts an engine if none is listening, health-checks it, and adopts one that is
already running. Owns the child process and terminates it on quit. This is what keeps
double-click-the-app working after decoupling.

**11. Rewire `ChatController` onto the client.**
Delete its in-process engine, seat engines and event pumps. Panes are driven by snapshots
plus the delta stream, keeping the smooth reveal and the pacing.

**12. Move attachments, endpoints and settings to commands.**
Uploads become `addAttachment`, seat edits become `updateSeat`, and the settings that the
engine owns are read back from the snapshot rather than duplicated in the app.

**13. App tests and a manual pass.**
A full conversation driven through the client against a real engine, with the UI checked.

## D. Entry points and packaging

**14. `--transport` on the CLI.**
`--transport webtransport|http|both`, default both during migration so nothing regresses.

**15. Start scripts.**
`start-app.sh` becomes "ensure an engine is running, then open the app". The web scripts are
unchanged in behaviour.

**16. Installer and trust.**
Persist the certificate at install time so the first launch does not prompt, and document
what to do if the fingerprint changes or trust is denied.

## E. Verification

**17. End-to-end over WebTransport.**
`chatbots-cli --check-transport`: connect as a client, round-trip a command, receive an
event, exit non-zero on failure. This is the smoke test the installer runs.

**18. The existing suite, and HTTP unchanged.**
372 tests plus the new ones. The website must still work through Caddy, verified with the
device capture harness.

**19. Audit against the brief.**
Re-check that no behaviour was lost in the move, and that the app no longer contains an
engine.

## F. Documentation

**20. Wiki and README.**
The architecture diagram, the macOS 26 requirement, and troubleshooting for trust failures.

**21. Final review.**
Read the diff for anything the tests cannot see, and confirm nothing is left half-migrated.

---

## Review of this plan

**Improvements made after writing it:**

* **Test `EngineService` before either transport** (task 3). My first draft tested WebTransport
  first, which would have made every dispatch bug look like a transport bug.
* **HTTP is not deleted** (tasks 2, 14). Caddy needs it, and keeping it means the migration can
  be verified against a channel known to work rather than only against the new one.
* **The certificate is persisted, not regenerated** (task 4). A fresh self-signed identity per
  launch would break pinning on every restart — the kind of thing that works in testing and
  fails in use.
* **Slow-client policy is explicit** (task 7). An event feed that back-pressures into the
  engine would let one stalled browser freeze a conversation.
* **The app supervises the engine** (task 10) rather than requiring the user to start two
  things — the decoupling must not cost the double-click experience.
* **Attachment uploads stay out of the event channel** (task 12): they are large and one-shot,
  so they belong on the request channel.

**Risks carried knowingly:**

* Self-signed trust may still prompt the first time. Task 16 persists the certificate to make
  this a one-time event, and the wiki documents it.
* `Network.framework` QUIC "degrades under heavy CPU contention" by the library's own
  documentation. Local inference *is* CPU contention. Task 9's reconnect logic is the
  mitigation; if sessions prove unreliable under load, that is an issue to file upstream.
