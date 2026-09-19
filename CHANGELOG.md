# Changelog

Every release, newest first. `RELEASE.md` §1.8 makes this file the announcement — the README carries
no release callout — and §1.9 requires it to point at the same tag as the release. The full detail of
each release is in its notes, linked below; this file is the index and the record of what was
**decided**, which is the part the task tracker deliberately does not hold: open work lives in the
[Project Tracker](https://github.com/Pummelchen/ChatBots/wiki/Project-Tracker), and what was tried,
measured, accepted or rejected lives here and in the closing commit.

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
