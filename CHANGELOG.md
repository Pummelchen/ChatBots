# Changelog

Every release, newest first. `RELEASE.md` §1.8 makes this file the announcement — the README carries
no release callout — and §1.9 requires it to point at the same tag as the release. The full detail of
each release is in its notes, linked below; this file is the index and the record of what was
**decided**, which is the part the task tracker deliberately does not hold: open work lives in the
[Project Tracker](https://github.com/Pummelchen/ChatBots/wiki/Project-Tracker), and what was tried,
measured, accepted or rejected lives here and in the closing commit.

## Unreleased

- **`tools/install.sh --model huihui9b` could not finish.** The installer's last completeness check
  accepted only `model.safetensors` or `model-00001-of-00001.safetensors`, so a **sharded**
  checkpoint — the Huihui 9B ships as `model-00001-of-00002` and `model-00002-of-00002` beside a
  `model.safetensors.index.json` — was reported as having "no weights file" *after* every byte had
  downloaded correctly, and the build step never ran. The check now mirrors the rule the loader
  actually applies, `ModelStore.isCompleteCheckpoint`: when an index is present it is the manifest
  and every shard it names must be beside it, and with no index a single `.safetensors` blob is
  complete. The two rules disagreeing is what produced this, so they are now stated once each and
  in the same terms. Verified both ways: the real single-blob 4B and the real sharded 9B are
  accepted, while an index naming two shards with one on disk, and an index naming nothing, are
  both refused. Found by installing the 9B for the first time — the path was documented but had
  never been exercised end to end.

- **A stored seat was drawn on the pane but never given to the engine, for two fields at once.** The
  app pushes the moderator and the endpoints when it connects, and it did not push a seat's backend
  or its checkpoint — so an engine launched on its own defaults won: a saved checkpoint was shown
  while the seat ran the default, and a seat the user had switched to an API backend was silently
  returned to the local engine, which is what made "Use API" look as though it switched itself off on
  the next launch. Both are now sent, and only when the engine's reported value differs, because
  changing a seat makes the engine release the weights it is holding. Found by measuring an engine the
  app had adopted rather than by reading: the seats stayed on the 4B while the saved setting said 9B,
  and `POST /api/seat` moved them at once.
- **A topic being typed is no longer overwritten.** Every snapshot adopted the engine's topic whenever
  it differed from the field, so the once-a-second poll wiped the field and a topic could not be
  entered at all; a freshly started engine's *default* topic also replaced the stored one on launch.
  The engine's topic is now adopted only when the engine is the one that moved it, or when it already
  holds a conversation to show.
- **Restart clears the run it replaces.** `startOrRestart` cleared the engine but left the previous run
  on screen — the paused pacer, a half-revealed reply and the old rate samples — so Restart read as
  "the session did not change". It now drops the same local state `reset` (Clear) always did, from one
  shared place.
- **Instant streaming, and a transcript that keeps the last line visible.** New "Instant stream"
  toggle, on by default: text is shown as the model emits it and the transcript follows it, instead of
  being revealed at a paced rate with the view moving only when a turn ends. The transcript also
  carries a bottom inset, so the end of a reply is no longer flush against the pane's edge and half cut
  off. The follow-scroll is driven by the document growing — never by a timer, which this view cannot
  use — and was checked against the freeze the scroll view documents: a streamed conversation left the
  main thread idle in the AppKit run loop rather than pinned in `flushTransactions`.
- **The entertainment prompt now grants the licence it was only hinting at.** The show's rules asked
  for conflict, mockery and sarcasm and then capped them three times ("never harassment", "clever beats
  crude", per-persona "rather than crude"), so the participants had no permission to be unpleasant. It
  now says plainly that they are characters, that no real person is involved, and that they may be
  rude, harsh, mean, crude, insulting and offensive, escalate, get personal and start fights — with the
  anti-patterns that actually spoil the show named (assistant phrasing, disclaimers, therapy-speak,
  sanitised corporate language). The per-persona conduct lines lost their caps too, and the licence is
  pinned by a test so a later tidy-up cannot soften it. One line is kept on purpose: the target is the
  characters in the room, not groups of real people.
- **DeepSeek is the default API endpoint, and its key no longer looks unconfigured.** A new API seat
  starts on `https://api.deepseek.com/v1` with `deepseek-flash` (the slug the API actually offers;
  `deepseek-v4.1-flash` does not exist) instead of a local URL the user has to replace. The endpoint
  sheet showed "not needed for a local server" for a key the app could in fact use, because it only
  consulted the Keychain: it now also recognises the built-in key for a host that key belongs to, so
  the field reads as configured. The key itself stays where it belongs — the environment or the
  gitignored `.secrets.env`, and only ever sent to `api.deepseek.com` — and the *decode* fallbacks are
  deliberately left alone, because those mean "an older saved payload" and repointing them would move
  an existing local-server configuration to DeepSeek.

- **The seat hand-over above was comparing its own clobbered copy, so it made things worse before it
  made them better.** It ran after the first snapshot had been applied, and applying copies the
  engine's backend into the panes — so the user's stored `openAIResponses` had already become the
  engine's `mlx` by the time the comparison ran: the backend was never sent (the defect it was added
  to fix stayed), and the *checkpoint* differed instead, so the engine rebuilt and loaded local
  weights for a seat that was never going to use them. Measured on a clean engine log, seven loads of
  a 3 GB checkpoint at launch became none. It now runs before the state is applied, then the moderator
  is pushed, then one snapshot is applied — so what is compared is still the user's stored choice.
- **Every message is capped at three sentences** in the entertainment rules: a long contribution ends
  the exchange it was meant to continue.
- **The show is about people.** The entertainment rules now steer the discussion to what a change does
  to the people living through it — work, family, routine, standing, what they gain and what they lose
  — and name ambition, resentment, loyalty, fear, envy and hope as the subject. A figure or a technical
  detail is allowed only to keep a claim honest and is never the argument; reaching for statistics or
  methodology to win turns the show into a briefing, which is the research mode's product.
- **The transcript no longer scrolls itself out from under a reader.** Following the stream, and the
  signal a finished turn sends, both yield once the transcript has been scrolled away from the bottom:
  new text keeps arriving below without moving the view, and scrolling back to the bottom hands it back
  to the stream. The check is made before the content is replaced, because afterwards the document has
  already grown and a view that was at the bottom no longer is.

## 1.2 — 2026-09-19

Tag [`v1.2`](https://github.com/Pummelchen/ChatBots/releases/tag/v1.2) from `56a009e`.
`ChatBots-1.2-macos-arm64.tar.gz`, 63,117,866 bytes, sha256
`9be43f9209cae3a27e5a77abdfb2b1004614d5c48e5c186cd9f1f0e58763abdd`.
Full notes: [docs/release-notes-v1.2.md](docs/release-notes-v1.2.md).

**No product code changed.** This is a repository-process release — not one source file differs from
1.1, and the notes say so rather than implying a delta. What it carries is how the repository keeps
its own record: this `CHANGELOG.md`, which `AGENTS.md` and `RELEASE.md` both already required; one
written standard for the task tracker, with open work in exactly one place; and the removal of the
audit's second table, which contradicted it. Nothing here is a reason to upgrade from 1.1.

## 1.1 — 2026-09-18

Tag [`v1.1`](https://github.com/Pummelchen/ChatBots/releases/tag/v1.1) from `9dffd25`.
`ChatBots-1.1-macos-arm64.tar.gz`, 63,117,703 bytes, sha256
`0ca450b4d8db03455e2580ce5800f165393f1b99661acfce64177036dba99309`.
Full notes: [docs/release-notes-v1.1.md](docs/release-notes-v1.1.md).

The release that follows the September 2026 pre-production audit.

- **The app no longer trusts whatever answers on the engine's port.** It used to adopt any process on
  `127.0.0.1:7790` and then send it every seat's cloud API key from the Keychain. The engine now
  writes a per-run token to its run directory — mode 0600, before it accepts a connection — and
  echoes it over a transport-only request; the app sends a key only to an engine that returns it.
  The token is deliberately absent from the HTTP API, so the unauthenticated web surface cannot
  learn it. It closes the window in which the port is taken *before* the engine starts; it does not
  make a same-user attacker impossible, because that user can read the file.
- **The engine's input is treated as untrusted.** Fetched pages and search summaries enter the
  prompt inside an explicit fence, and a topic or seat name can no longer forge a transcript
  boundary or a speaker line.
- **Secrets on disk are private**, and programs the engine starts inherit a short allow-list of
  variables rather than the environment — never a cloud key.
- **Both style gates now run `--strict` against zero**, with the waiver caps deleted: SwiftLint from
  206 findings to 0, swift-format from 306 diagnostics to 0.

Accepted, and recorded rather than fixed — the repository owner reviewed these and signed them off
on 2026-09-18: the unauthenticated `/api` surface reachable from the LAN, the every-interface
plaintext default, the DNS-rebinding gap in the same-origin check, and the limits of the session
token above. A shared-secret bearer token with a loopback default bind was considered for the first
three and **declined**; authentication and a Host allow-list were both declined for the rebinding
gap. `SECURITY.md` carries the reasoning and the wiki's
[Accepted limits](https://github.com/Pummelchen/ChatBots/wiki/Accepted-Limits) states it for users.

Verified a second time on an independent host: a fresh clone of the same commit and toolchain passed
all nine gates with the same 1102 tests in 201 suites. The one honest difference is recorded with it —
the coverage total there measured a different object set and is not comparable.

## 1.0 — 2026-09-17

Tag [`v1.0`](https://github.com/Pummelchen/ChatBots/releases/tag/v1.0) from `9806228`.
`ChatBots-1.0-macos-arm64.tar.gz`, 62,818,504 bytes, sha256
`4fa02c79d52e334363189ebf33173a8e4491e7e62fe79b838622c5c822d1bbc6`.
Full notes: [docs/release-notes-v1.0.md](docs/release-notes-v1.0.md).

The first release: two or more local MLX models arguing with each other on a Mac, watched from the
SwiftUI app or a browser, with local inference, OpenAI-compatible backends and Tavily tools. Named
as not checked in its notes: inference with the shipped checkpoint (no weights in a checkout),
notarisation (ad-hoc signing only), a Swift job in CI (deliberate), and semgrep's rule set (fetched
at scan time). An earlier `1.0.0` release of the same commit was withdrawn unpublished-in-practice
and re-cut as `1.0` at the owner's request; its tag is gone.
