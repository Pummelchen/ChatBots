# ChatBots 1.1 — release notes

ChatBots runs two or more local MLX models against each other on a Mac, watched from a SwiftUI
app or a browser. 1.1 is the release that follows a full pre-production audit of the code, the
scripts and the release machinery: 107 findings were recorded, every one is closed, and the checks
that did not run are named last. Every claim below names the check that would fail if it stopped
being true.

## The archive

`ChatBots-1.1-macos-arm64.tar.gz` and its `.sha256` sit on the release page. Inside,
`ChatBots.app` carries the engine `chatbots-cli`, the probe `chatbots-probe` and MLX's Metal
kernels in `Contents/MacOS/`; `bin/` holds the executables and kernels again, with `LICENSE`,
`THIRD-PARTY-NOTICES.md`, `SECURITY.md` and `README-binaries.txt`. No model weights.

Backed by `tools/make-release.sh`, which assembles the tree and writes the digest with
`shasum -a 256`; `tools/third-party-notices.py` checks the notice inventory against
`Package.resolved` in CI, and `tools/make-app.sh` fails when the notices are missing.

## Apple silicon only, macOS 26 or later

Native `arm64`, no Intel build and no universal binary; macOS 26 is the floor, because MLX runs on
the GPU and WebTransport requires it. Backed by `tools/make-release.sh`, which runs `lipo -archs`
over every Mach-O file in the staged archive and fails unless each reports exactly `arm64` (at
least three must be found), and by the CI check that `LSMinimumSystemVersion` equals
`Package.swift`'s `.macOS(.v26)`.

## The version it reports

This release is `1.1` and the tag is `v1.1`. `VERSION` at the repository root is the one
authoritative value for it, and the bundle's `CFBundleShortVersionString` and `CFBundleVersion`
are both written from that file, so a person can say what they are running from the artefact
alone. Backed by `tools/check-identity.sh` (CI, and gate 9 of `tools/mac-checks.sh`), which fails
on a malformed `VERSION`, a copy in `tools/make-app.sh`, or missing notes; by
`tools/make-release.sh`, which re-reads both plist keys out of the built bundle; and by
`tools/set-version.sh <X.Y[.Z]>`, the one command a bump needs.

## The engine now proves who it is

The headline change is a per-run session token (AUDIT-0058). Before it, the app adopted whatever
process answered on the engine's transport port, `127.0.0.1:7790`, and then pushed every seat's
cloud API key from the Keychain to it. The transport uses `localDevelopmentSelfSigned`, which does
not verify the peer, so a same-user process that took the port before the real engine started was
adopted and handed the keys.

Now the engine writes 32 random bytes as lowercased hex to `session-token` in its run directory —
mode `0600`, written through a sibling `O_CREAT|O_EXCL` file that is `fchmod`ed to `0600` and
renamed into place, with a missing run directory created `0700` — before either transport accepts a
connection. It answers a transport-only `identify` request with that token, and refuses when it
holds none. The app reads the same file and adopts an engine only when the echo matches what it
read; an engine that cannot prove itself is reported to the user and is sent nothing. The app
launches the engine with `--run-directory` explicitly, so the two cannot resolve the run directory
by different rules.

The token is deliberately absent from the HTTP API: `POST /api/identify`, `/api/identity` and
`/api/session-token` are 404, and no snapshot carries it, so the unauthenticated web surface cannot
learn it even by asking. That is what makes the control usable on a build whose web side is
LAN-reachable by design. It closes the window in which the port is taken *before* the engine starts.

It does not make a same-user attacker impossible. The file is `0600` but readable by any process
running as the same user; a token also survives an engine killed with `SIGKILL`, because only the
graceful shutdown path removes it, and the app does not clear it before launching (that would race a
second instance). The engine's certificate fingerprint is still reported and logged rather than
enforced — the client cannot observe the peer certificate — so the reported value does not reveal an
impersonating loopback peer. These limits are recorded with the finding and in `SECURITY.md`, not
left implicit. One behaviour change to expect: an engine started before this change cannot identify
itself, so the app will not adopt it. That is intended, and it is the case to expect on the first
run after updating.

Backed by `SessionTokenTests.swift` (a `0600` file in a `0700` directory, 32 random bytes as
lowercased hex, replacement, absent-is-nil, owner-only comparison), `SessionTokenTransportTests.swift`
("A client is answered with the token the engine was started with", "An engine started without a
token refuses rather than echoing an empty one"), `SessionTokenHTTPTests.swift` ("There is no HTTP
route that asks the engine to identify itself", "No snapshot the HTTP API serves contains the
token"), and `Tests/ChatBotsAppTests/EngineIdentityTests.swift` ("Only the token this run wrote is
accepted", "With no token on disk, nothing is adopted", "The refusal names the port and promises no
credentials"). The control was also watched against a live `chatbots-cli`
(`AUDIT/evidence-0058-live.md`), and all nine Mac gates pass with 1102 tests in 201 suites
(`AUDIT/evidence-0058-mac-checks.log`).

## The rest of the security work

- **Private file modes.** `.secrets.env` is restricted to `0600` when it is group- or
  world-readable (AUDIT-0010); the kept-conversation directory is created `0700` and
  `conversations.json` `0600` (AUDIT-0017); the TLS key and certificate are generated inside a
  `0700` staging directory and moved into place, so the key is never world-readable even for an
  instant, `permissions(of:)` uses `lstat`, and `tools/start-app.sh` creates `.run` with
  `install -d -m 700` (AUDIT-0036). Backed by `BuiltInKeyTests.swift`,
  `StoreRecoveryTests.swift` and `CertificateIdentityIntegrityTests.swift`, and by shellcheck over
  `tools/start-app.sh`.
- **The conversation trace is off when it says it is.** `CHATBOTS_TRACE_API=off` (and `disabled`,
  `none`, any case, trimmed) now leaves it off instead of turning it on (AUDIT-0051), and the trace
  header names only scheme, host and path, dropping userinfo, query and fragment, so a key embedded
  in the base URL is not written to standard error (AUDIT-0052). Backed by `TraceSwitchTests.swift`.
- **Redirects and lookalike hosts are refused.** The Tavily client reports a redirect instead of
  following a 302 with the Bearer key attached (AUDIT-0011); the `/v1/models` probe uses the same
  endpoint policy and the same redirect-refusing session as generation (AUDIT-0049); link-local and
  private refusal parses the host, so the decimal, hex and IPv4-mapped IPv6 spellings are caught
  (AUDIT-0050); `fetch_page` refuses loopback, private, link-local and the unspecified address
  (AUDIT-0014). Backed by `ClientsSearchTests.swift`, `EndpointPolicyTests.swift` and
  `WebToolValidationTests.swift`.
- **A checkpoint id is a name, not a path.** Every `/`-separated component must be non-empty and
  not `.` or `..`, and the absolute-path candidate is gone, so a model id cannot escape the models
  root (AUDIT-0002). Backed by `ShardedCheckpointTests.swift`.
- **Tool results and API-set text are fenced.** Fetched web content and search summaries enter the
  prompt inside an explicit untrusted-data fence (AUDIT-0015); the API-settable topic and seat
  names can no longer draw a second transcript boundary ahead of the real one in the synthesis
  prompt (AUDIT-0016); a topic or speaker name cannot forge a `[timestamp] NAME` transcript line
  (AUDIT-0006). Backed by `TurnLoopRuleTests.swift`, `TurnLoopModelTests.swift`,
  `ResearchPromptTrustTests.swift` and `TranscriptWriterTests.swift`.
- **Children get an allow-listed environment.** `textutil` and `openssl` receive `PATH`, `HOME`,
  `TMPDIR`, `LANG`, `LC_ALL`, `USER`, `LOGNAME` and `OPENSSL_CONF` when set — never `TAVILY_API_KEY`,
  `DEEPSEEK_API_KEY` or `CHATBOTS_TRACE_API` (AUDIT-0047). `SystemProcess.childEnvironment` takes the
  environment to draw from so the allow-list is checkable without running a child; the change is
  covered by the build and the batch suite, not by a dedicated test.
- **The app only execs its own engine.** The `/usr/local/bin/chatbots-cli` fallback is gone, so the
  launch path cannot be pointed at a binary planted in a world-writable directory (AUDIT-0062).
  Backed by the app test bundle and the full suite.
- **The docs now say what the code does.** `SECURITY.md` states where the TLS key really lives
  (`RunDirectory.resolve`: `.run/` in a checkout, `~/Library/Application Support/ChatBots/` for an
  installed build) rather than claiming `.run/` for both (AUDIT-0040), and the fingerprint is
  described as reported, not enforced (AUDIT-0032). Backed by `CertificatePinClaimTests.swift`.

## The engine

- **Hostile inputs no longer crash it.** `/api/device` bounds width and height to
  `maximumViewportDimension = 100_000` before the match arithmetic (AUDIT-0001); a
  checkpoint-declared context window is clamped to `MLXEngine.maximumContextWindow = 1_048_576` and
  the generation cap adds with `addingReportingOverflow` (AUDIT-0043); a PDF's page count is clamped
  with `max(0, ...)` before the range (AUDIT-0023). Backed by `DeviceProfileTests.swift`,
  `GenerationCapTests.swift` and `RealExtractorTests.swift`.
- **Attachments are bounded at intake.** The declared pixel count is now measured for PNG, JPEG,
  GIF and WebP too, before the bytes pass through to be decoded later (AUDIT-0004); the sum of
  attached bytes is capped at 256 MB, checked on the main actor with the append (AUDIT-0005); a
  mid-file read error is reported instead of returning the bytes read so far as the whole document
  (AUDIT-0022); `textutil` converts the bounded bytes staged into a `0600` temporary file instead of
  re-opening the caller's path (AUDIT-0024). Backed by `ImageUploadTests.swift`,
  `AttachmentMediaTests.swift`, `AttachmentIntakeTests.swift`, `EngineServiceTests.swift` and
  `RealExtractorTests.swift`.
- **A kept conversation is not lost quietly.** A store that cannot save is reported once through a
  notice instead of being discarded (AUDIT-0003); `deleteAll` also removes a stranded
  `conversations.json.tmp`, so a deleted history is not resurrected (AUDIT-0007); a damaged
  temporary is reported as unreadable and is not overwritten (AUDIT-0008). Backed by
  `ConversationReportingTests.swift` and `StoreRecoveryTests.swift`.
- **The search and tool budgets are charged what they spend.** A turn that produces no text still
  charges the research budget (AUDIT-0012); a basic-to-advanced retry is charged as two billed
  searches rather than one (AUDIT-0026); one turn dispatches at most eight tool calls across all
  rounds (AUDIT-0013). Tavily's own answer is inserted as the first hit instead of being decoded and
  dropped (AUDIT-0025), and its response body is read to a 16 MiB cap (AUDIT-0027). Backed by
  `ConversationReportingTests.swift`, `ResearchSearchBudgetTests.swift`, `TurnLoopRuleTests.swift`
  and `ClientsSearchTests.swift`.
- **Turn-loop and load correctness.** A loop-detected round now takes `assembler.finish()`, so the
  up-to-seven characters the thinking stripper held back are not dropped from the answer
  (AUDIT-0048); a lowercased attachment id removes the file instead of being reported absent
  (AUDIT-0046); an unload can no longer be overwritten by a load that completes afterwards, through
  `MLXEngine.loadGeneration` (AUDIT-0044); the session-reuse probe takes the same `MLXGate` as
  generation (AUDIT-0045). Backed by `TurnLoopRuleTests.swift` and `AttachmentRemovalTests.swift`;
  the two concurrency changes have no dedicated test and are covered by the build and the transport
  suites.
- **Model store and classification.** A failed model directory creation is reported to standard
  error instead of silently pointing the downloader at a path that was never created (AUDIT-0009);
  the two-character `o3`/`o4` vision markers match whole tokens rather than substrings (AUDIT-0019);
  a wide or non-mobile viewport resolves to a real desktop profile instead of always `nil`
  (AUDIT-0020). Backed by `VisionCapabilityTests.swift` and `DeviceProfileTests.swift`;
  `prepare()` is a diagnostic change covered by the build.

## The transport

- **A reconnect is not poisoned by the old reader.** `teardown()` bumps a reader generation before
  it cancels, and a read loop that wakes after it returns without touching the shared reply or
  error state, so the new session cannot fail with the old session's error (AUDIT-0033). Backed by
  `TransportLifecycleTests.swift` and `WebTransportSessionTests.swift`.
- **Shutdown and writes are bounded.** Live sessions are closed in a task group rather than one
  after another on the main actor (AUDIT-0037); a server-wide `bufferedFrameBytes` budget of
  twice the maximum message bounds what live sessions can hold (AUDIT-0038); a per-session
  `SendQueue` actor serialises the writer task and every reply path (AUDIT-0042). Backed by
  `WebTransportSessionTests.swift` and `TransportLifecycleTests.swift`; a `SendQueue` test is not
  possible without a stream.
- **A session is closed once, and says why it ended.** The startup watchdog and `refuseFraming`
  remove the session before closing it, so the `defer` in `serve` agrees on ownership and the
  transport's "close is not called twice" rule holds (AUDIT-0034); a session that cannot open its
  stream records a reason instead of looking like a clean close (AUDIT-0035). Backed by
  `WebTransportSessionTests.swift`.
- **The transport check's banner is evidence.** It waits for the event collector against a
  five-second deadline instead of a fixed 400 ms sleep, and reports the session the check actually
  made rather than a hardcoded `1` (AUDIT-0039). Backed by `TransportCheckTests.swift`.

## The HTTP surface

- **Slow peers cannot hold the server.** A wall-clock `maximumRequestDuration` (300 s) is armed
  once at accept and never re-armed, so a connection that trickles bytes just inside the idle
  deadline is still dropped (AUDIT-0069); the event stream closes once 256 frames are outstanding to
  a client that has stopped reading (AUDIT-0070). Backed by `HTTPLimitTests.swift`,
  `EngineStateEventStreamTests.swift` and `HTTPServerTests.swift`.
- **Responses tell the truth.** 401, 403, 415, 422, 429 and 431 have their own reason phrases
  instead of `OK`, with a status-class fallback (AUDIT-0072); a bare CR or LF inside a header value
  is refused (AUDIT-0075). Backed by `HTTPTests.swift` (`HTTPReasonPhraseTests`) and
  `HeadParsingTests.swift`.
- **`/api/seat` refuses what it cannot honour.** An unknown `thinking` or `backend` is a 400 with
  the accepted values instead of a silent 200 (AUDIT-0073), and a refused model change no longer
  renames the seat on its way to the 409 (AUDIT-0074). Backed by `MalformedBodyTests.swift`.
- **The event feed keeps a high-water mark** of sequence numbers instead of one UUID per turn for
  the life of the process (AUDIT-0076). Backed by `EngineStateEventStreamTests.swift` and
  `HTTPServerTests.swift`.
- **An endpoint change takes effect.** A seat whose base URL or API key changes has its OpenAI
  engine rebuilt, instead of the snapshot showing a change the live client never received
  (AUDIT-0057). Backed by `ConversationReportingTests.swift`.
- **The OpenAI stream is bounded and honest.** A line past `maximumEventLineBytes` (1 MB) fails the
  stream rather than being buffered, and a non-2xx body is read to 4 KB (AUDIT-0053); an
  unparseable `data:` event fails the stream instead of being skipped and finished on a later
  well-formed event (AUDIT-0056). Backed by `ClientsStreamTests.swift`.
- **Endpoint routing matches hosts, not text.** Parameter-set inference matches the parsed host
  (or a proper subdomain of `openai.azure.com`/`openrouter.ai`) rather than a substring, so a
  lookalike cannot silently drop sampling parameters (AUDIT-0054), and a base URL with a query or
  fragment no longer swallows the API path (AUDIT-0055). Backed by `EndpointPolicyTests.swift`.

## The command line

- **The Tavily key can no longer be passed on the command line.** `--key` exits 2 and names the two
  supported ways — `TAVILY_API_KEY` in the environment and `.secrets.env` at the project root —
  because a value in argv is readable by every process through `ps` and kept in shell history
  (AUDIT-0021).
- **Flags only another mode can honour are refused.** `--port` and `--share-base` without
  `--serve`, and `--solo` without `--benchmark`, each exit 2; `--attach` with a missing or
  flag-shaped value is refused instead of appending an empty path (AUDIT-0094).
- **A failed run says so.** The default headless run exits 1 when a turn failed or when no turn
  produced a chat message (AUDIT-0095); the memory probe reports a failed turn and exits 1 instead
  of printing a plausible table for turns that made no tokens (AUDIT-0093); the session probe sends
  its follow-up questions with role `.user` instead of `.assistant`, so it measures the
  growing-prefix conversation it claims to (AUDIT-0092).

Backed by `ConversationReportingTests.swift` ("A failed turn is counted, because the run's status
does not stay failed") and the build; the parser refusals and the probe paths are exercised by the
CLI build and the batch suite, not by a dedicated test.

## The app

- **A refusal is treated as a refusal.** `ChatController.deliver` returns false for `.refused` and
  `.failed`, so a rejected steer no longer clears the moderator's draft and a refused checkpoint is
  no longer shown as applied (AUDIT-0059). Backed by `Tests/ChatBotsAppTests/RefusalTests.swift`.
- **Closing the window disconnects the controller** before the engine is shut down, so the QUIC
  session and the one-second poll task do not outlive the window (AUDIT-0066).
- **The supervisor is single-instance and bounded.** `start()` guards `.starting` as well as
  `.running`, so a second call cannot launch a rival engine on the same port (AUDIT-0063); a failed
  launch closes its log handle instead of leaking it (AUDIT-0064); the log tail reads only the last
  few kilobytes through a `FileHandle` seek rather than decoding the whole never-rotated file on the
  main actor (AUDIT-0065).
- **Attachments are read off the main actor**, in the background task the code's own comment always
  promised, so several large files no longer block the UI before the upload starts (AUDIT-0061).
- **A corrupted text-scale preference is sanitised** instead of trapping in `Int((scale * 100).rounded())`
  or feeding the window's `NSSize` (AUDIT-0067). Backed by `ZoomStepTests.swift`.
- **Keychain writes report failure.** `storeKey` updates the item in place and only adds when there
  is nothing to update, and the endpoint sheet shows an error under the field, so a key that could
  not be stored is no longer shown as configured (AUDIT-0068).

The app test bundle and the full suite in `tools/mac-checks.sh` are the backing for the fixes that
have no named test; where a fix removes a cancellation-blind or resource-leaking path rather than
adding observable behaviour, that suite plus the build is the check that it did not regress.

## The web front end

- **Follow is turned off when the reader scrolls**, including in panes created after start-up: the
  listener is attached in the capture phase on the document and filters to `#thread` or
  `.transcript`, so streaming no longer yanks every pane to the bottom (AUDIT-0088).
- **A typed topic is not dropped.** Start commits a changed topic and awaits it before posting
  `/api/start`, so the previous topic cannot win the race (AUDIT-0089).
- **Cmd/Ctrl+Enter in the message box no longer also presses Start.** The handler stops
  propagation, so one keystroke cannot send the message and reset the conversation (AUDIT-0090).
- **Enter renames once.** `startRename` returns immediately when the button is already
  `contentEditable`, so the commit no longer installs a second handler pair that re-posts the
  rename (AUDIT-0091).

Backed by `python3 tools/embed-web.py --check`, which fails when the generated `WebAssets.swift` is
stale, and by gate 8 of `tools/mac-checks.sh` (eslint and prettier) and the same two steps in CI;
the page's interaction fixes have no browser test.

## Building and releasing

- **A reused gate log is bound to its commit.** `tools/mac-checks.sh` prints
  `mac-checks commit: <sha>` from `git rev-parse HEAD`, and `tools/make-release.sh --gates-log`
  requires that line in addition to the passing banner, so a log from another commit cannot be
  reused as evidence (AUDIT-0078).
- **A signature that fails fails the build.** `tools/make-app.sh` exits 1 when it cannot ad-hoc sign
  the bundle or when the signature does not verify, unless `--allow-unsigned` is passed, and
  `tools/make-release.sh` runs `codesign --verify --strict` on the built bundle independently
  (AUDIT-0079).
- **`--scratch` is refused unless it is under the checkout's `.build`**, so the `rm -rf` in the
  release path cannot be pointed at the tree or the filesystem (AUDIT-0083).
- **Model weights are verified against a published hash.** `tools/hf-file-list.py` writes the
  per-file SHA-256 the hub publishes for a Git LFS object, and the installer verifies a file against
  it at all three success points — already present, resumed and freshly downloaded — removing a
  mismatch rather than letting a resume build on it (AUDIT-0082). A repository id whose last
  component is empty, `.` or `..` is refused (AUDIT-0086).
- **Shell fixes.** The installer's partial-download guidance names `$MODELS_DIR`, the variable that
  exists, instead of an unbound `local` that aborted the diagnostic under `set -u` (AUDIT-0080);
  the start-web wrappers expand an empty `DEFAULTS` array portably on macOS's bash 3.2 (AUDIT-0081).
- **The swift-format gate can no longer pass by doing nothing.** It checks the pipeline's exit
  status and that the file list is non-empty, so a tool that fails before linting cannot report
  zero diagnostics as a pass (AUDIT-0084).
- **The installer offers the whole catalogue.** On a terminal with no options it lists the
  checkpoints with sizes and asks which further ones to fetch; `--model <alias|id>` (repeatable,
  comma-separated) adds one and `--models all` takes the catalogue (~12 GB); from a pipe nothing is
  asked, and `--yes` suppresses the question. The shipped checkpoint is always installed. The
  catalogue is read out of `ModelCatalog.swift` rather than copied into the shell (commit
  `b0fd433`). Backed by `ModelChoiceTests.swift` and `DefaultCheckpointTests.swift` for the
  catalogue and the derivation; the installer's menu itself is covered by `bash -n` and shellcheck,
  not by a behavioural test.
- **The DevTools websocket client is bounded.** A frame past `MAX_FRAME_BYTES` (32 MiB), and a
  fragmented message whose pieces total more than that, are refused instead of being read into
  memory (AUDIT-0087).

Backed by the scripts themselves — `bash -n` and `shellcheck -S style` run over every tracked
`.sh` in CI — and, for the verification paths, the checks named in each item.

## The repository's own standards

- **The two style gates run `--strict` against zero, and the waiver caps are gone.** SwiftLint went
  from 206 findings to 0 and swift-format from 306 diagnostics to 0; `tools/analysis-waivers.txt`
  now carries only the semgrep findings this project accepts (AUDIT-0029 and the tasks it was split
  into). Backed by gates 5 and 6 of `tools/mac-checks.sh`, which also check the tool's exit status,
  so a run that linted nothing cannot pass as clean.
- **Python has a committed `ruff.toml`** selecting the rules the audit brief names — bare except
  (E722), mutable defaults (B006), `assert` validation (S101), pytest style (PT011), naive
  datetimes (DTZ005) and unspecified encoding (PLW1514, with preview) — and all findings are fixed
  (AUDIT-0030). Backed by `ruff check tools/` and `ruff format --check tools/` in CI and by the rule
  proofs in `AUDIT/tool-coverage.md`.
- **JavaScript has a pinned formatter and linter.** `eslint` 10.10.0, `prettier` 3.9.8 and
  `globals` 17.12.0 come from the committed `package-lock.json` via `npm ci`; a missing install
  fails the ninth Mac gate and CI rather than skipping (AUDIT-0031).
- **Encoding and repository hygiene.** Every text-file operation in `tools/*.py` passes an explicit
  encoding (AUDIT-0085), and `.gitignore` anchors the checkpoint ignore to the repository root, so a
  new file under `Sources/ChatBotsCore/Models/` is no longer silently ignored (AUDIT-0096). Backed
  by `ruff`/`pyright`, the `--check` embed tools and `git check-ignore`.
- **A test that could not fail now can.** The vision-capability test that accepted `.unknown` or
  `.supported` asserts `.unknown` exactly, and the two-character marker rule has a
  positive-and-negative test (AUDIT-0028, AUDIT-0019). Backed by `VisionCapabilityTests.swift`.
- **The sweep and the second host.** Phase D re-ran every scanner CI runs over the frozen tree; the
  two red gates it made are fixed (AUDIT-0106, AUDIT-0107). Phase E ran the nine Mac gates on
  `MacBook-AB.local`, an independent host, on a fresh clone of the same commit. Backed by
  `AUDIT/evidence-phase-d-sweep.log` and `AUDIT/evidence-phase-e-host.md`.

## What this release was checked with

`tools/mac-checks.sh` runs nine gates on the release Mac: file sizes, `swift build --build-tests`
with warnings-as-errors, `swift test --enable-code-coverage`, an `llvm-cov` report over `Sources/`,
`swiftlint lint --strict`, `swift-format lint --strict`, the two Node web-rule checks (34 cases for
the streaming merge and 12 for the verdict rule), `eslint` and `prettier` over the JavaScript, and
`tools/check-identity.sh`. The suite measured 1102 tests in 201 suites against the audit's baseline
of 1048 in 195; both style gates report zero under `--strict`; the coverage gate reports a number
and sets no floor, so it cannot fail on a coverage drop. `tools/make-release.sh` then builds from a
clean scratch path, checks the bundle's signature, scans the log for warnings from `Sources/` or
`Tests/`, and re-reads the bundle's identity before packing.

Phase E re-ran all nine gates on `MacBook-AB.local`, an independent host with the same pinned
toolchain, on a fresh clone of commit `aa7a942`: 1102 tests in 201 suites — the same count the
primary host reports — with `--strict` clean on both style gates (`AUDIT/evidence-phase-e-host.md`,
`AUDIT/evidence-phase-e-final-macbook-ab.log`).

CI runs the Linux-side gates on every push and pull request: generated files, file sizes,
third-party notices, `bash -n` and `shellcheck`, `py_compile`, `ruff check` and `ruff format
--check`, `pyright`, `eslint` and `prettier`, `gitleaks` over the full history, `semgrep` through
`tools/semgrep-waivers.py`, `osv-scanner` and `tools/check-identity.sh`. None of them is advisory:
a finding fails the job.

## Accepted risks

These are decisions on the record, not fixes. The repository owner reviewed them and accepted them
on 2026-09-18, and the behaviour each describes is still present and still deliberate.

- **The unauthenticated API, on the LAN by design (AUDIT-0018, AUDIT-0077).** The engine itself
  binds `127.0.0.1` only, but `tools/start.sh` runs Caddy from the shipped `Caddyfile`, whose site
  address carries no host and therefore listens on every interface. `/api/*` and `/s/*` are proxied
  from there to the loopback engine with no password, so anyone who can reach the site can read
  every kept conversation, drive the run controls and open a share page. That is what lets a phone
  on the same Wi-Fi use the interface; `--local-only` inserts `bind 127.0.0.1` and keeps all of it
  on this Mac. The alternative on the table was a shared secret on state-changing routes plus a
  loopback default bind — a contract change across four consumers — and it was declined.
- **DNS rebinding defeats the same-origin check (AUDIT-0071).** The check compares `Origin` against
  `Host`/`X-Forwarded-Host`, two names the browser derives from the URL it fetched, so a page that
  DNS-rebinds to the Mac is same-origin to the check. Accepted as part of the LAN-trust model above;
  authentication and a Host allow-list were both declined.
- **The session token's limits (AUDIT-0058, the parts left open).** The token file is `0600` but
  readable by any process running as the same user, so it closes the window in which the port is
  taken before the engine starts; it does not make a same-user attacker impossible. A token also
  survives an engine killed with `SIGKILL`, because only the graceful shutdown path removes it. The
  engine's certificate fingerprint is reported and logged but not enforced, and the client cannot
  observe the peer certificate.

## Checks that did not run, and why

- **Real inference with the shipped checkpoint — not checked, no input.** This checkout has no
  model weights: `models/` is absent and git-ignored, and `tools/install.sh` downloads about 3 GB
  into it. No checkpoint could be loaded, so none was; `TurnLoopModelTests.swift` ("The turn loop
  runs on a stubbed model") covers prompt assembly, streaming and the returned turn without weights.
- **Notarisation and Developer ID signing — not checked.** There is no Apple Developer ID.
  `tools/make-app.sh` ad-hoc signs each component and the bundle (`codesign --sign -`) and now fails
  when it cannot, and `tools/make-release.sh` verifies the built bundle, but nothing notarises, so a
  downloaded copy is refused by Gatekeeper; `README-binaries.txt` carries the
  `xattr -dr com.apple.quarantine` command for a user who has verified the digest.
- **A Swift job in CI — not checked, deliberately.** No hosted runner image is macOS 26 on Apple
  silicon with MLX, so the Swift gates cannot run there; `tools/mac-checks.sh` on a Mac is the Swift
  gate.
- **The semgrep rule set — not reproducible from this repository.** The scan runs with
  `--config auto`, so its rules are fetched from the Semgrep registry at scan time and no version
  pin here covers them: the scan ran, but the policy did not come from this checkout.
- **The independent host's coverage number is not comparable.** Gate 4 printed a much lower total
  on `MacBook-AB.local` than on the primary host because it measured a different object set; the
  gate reports a number and enforces no floor, and the record states this rather than glossing over
  it.
- **ThreadSanitizer — no run recorded.** `AUDIT/tool-coverage.md` names
  `swift test --sanitize=thread` as the Swift memory/sanitizer tool, but no audit log or ledger
  entry records a run of it or its result. The concurrency work was checked instead by the Swift 6
  language mode with warnings-as-errors and by the committed
  `AUDIT/probes/strict-concurrency-probe.swift`, which a scratch package carrying the same settings
  builds and refuses.
- **A Python dependency audit — nothing to scan.** There is no `requirements.txt` or lock file for
  `tools/`, so there are no third-party Python packages to check; `AUDIT/tool-coverage.md` records
  `pip-audit` as having no target.
- **Some fixes have no behavioural test.** The engine's `SendQueue`, the load/unload generation,
  the session-reuse probe's Metal gate, several app lifecycle changes and the installer's
  interactive catalogue menu are covered by the build and by the suites that drive the real paths,
  not by a test that asserts the specific behaviour. They are named here rather than implied to be
  tested.

## Checksum

The digest and archive size are substituted at publish time, from the archive that was built:

```
SHA256_PENDING  ChatBots-1.1-macos-arm64.tar.gz
ARCHIVE_BYTES_PENDING  bytes
```
