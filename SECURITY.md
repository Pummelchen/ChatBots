# Security policy

## Reporting a vulnerability

Use GitHub's private advisory form:

**https://github.com/Pummelchen/ChatBots/security/advisories/new**

Please do not open a public issue for anything that could put a user at risk. A report is
acknowledged when it is read, and the fix and the disclosure are agreed with you before
anything is published.

## What this project does on the network

Worth knowing before you report, because several things that look like leaks are the design:

* **The models are local.** Inference runs in this process on Apple's MLX framework. Prompts,
  transcripts and attachments are not sent anywhere unless you point a seat at a cloud
  endpoint yourself.
* **The engine is bound to loopback.** The HTTP server and the WebTransport listener both bind
  `127.0.0.1` and are not reachable from the network.
* **The website, once you start it, carries the engine's pages onto the network with it.**
  `tools/start.sh` runs Caddy from the shipped `Caddyfile`, whose site address carries no host and
  therefore listens on **every** interface. `/api/*` and `/s/*` are proxied from there to the
  loopback engine, so anyone who can reach the site can read every kept conversation, drive the run
  controls and open a share page. That is deliberate — it is what lets a phone on the same Wi-Fi use
  the interface — and `tools/start.sh --local-only` inserts `bind 127.0.0.1`, which keeps all of it
  on this Mac.

  **Accepted risk, signed off.** The audit recorded this exposure as AUDIT-0077 and the DNS-rebinding
  gap in the same-origin check as AUDIT-0071, and the repository owner reviewed both and accepted
  them on 2026-09-18, together with the unauthenticated `/api` surface as AUDIT-0018. The reasoning is
  the one above: the LAN is the trust boundary, the phone-on-the-Wi-Fi case is the point of the
  feature, and `--local-only` is the supported way to remove the exposure. The alternative on the
  table was a shared-secret on state-changing routes plus a loopback default bind — a contract change
  across four consumers — and it was declined. Anyone deploying this on an untrusted network should
  pass `--local-only` or front it with their own authentication; the three findings stay in
  `AUDIT/ledger.json` as accepted with this paragraph as the record.
* **A share link is not uploaded and not hosted anywhere.** `/s/<id>` is a page the engine renders
  from the conversation it already holds, and the transcript stays on the machine that made it.
  What that does *not* mean is that the link is private: it is served through whatever serves the
  website, so any device that can reach the site and has the URL can read that one conversation —
  and the API beside it can list them all. Treat a link as being as public as the website is.
* **Web search goes to Tavily**, and only when a seat has search enabled and a key is
  configured. The query text leaves the machine; nothing else does.
* **Cloud seats send the conversation to that endpoint.** That is the point of them. The
  built-in DeepSeek key is only ever sent to `api.deepseek.com` — the host is compared exactly
  rather than by substring, so a lookalike domain cannot be handed a real key
  (`BuiltInKeys.allowedHosts`).
* **One switch writes the conversation somewhere else, and it is off unless you set it.**
  `CHATBOTS_TRACE_API=1` makes the client print each request to the endpoint on standard error, so
  that a protocol problem can be seen. It prints the first 2 000 characters of the body with attached
  images left out — the trace line says how many were omitted — and it does not print the API key.
  Where that output ends up
  is wherever standard error goes — a terminal, or a log file you have pointed it at — so treat it as
  writing the conversation to that place. The trace names only the destination — scheme, host
  and path, with any userinfo, query and fragment removed — so a key embedded in the base URL
  is not printed either. `0`, `false`, `no`, `off`, `disabled` and `none` (any case, surrounding
  whitespace ignored) leave it off; any other value turns it on.

## The local trust boundary, stated honestly

The desktop app reaches the engine over WebTransport with the transport library's
`.localDevelopmentSelfSigned` policy. That is a loopback-only bypass of platform certificate
validation: **the engine's fingerprint is reported and logged but not enforced, and the client
cannot observe the peer certificate to check it.** A malicious process already running as your
user could present its own certificate and be accepted — and the reported fingerprint, which is
the engine's own claim about the file it loaded, would not reveal it. It is
accepted because the alternative is no encrypted local channel at all, and because a process
that can run as you can read the engine's files directly. See the comment at the top of
`Sources/ChatBotsCore/Transport/WebTransportClient.swift`.

## Keys

* **No key is compiled into this repository, and none may be.** A key in the source is a key in
  every clone; this project is public. One was, early on, and had to be revoked — which is why
  `TavilyKeyTests` now fails if a key appears in `TavilyClient.swift` again.
* Keys are read from the environment (`TAVILY_API_KEY`, `DEEPSEEK_API_KEY`) or from
  `.secrets.env` at the project root. That file is gitignored and must never be committed.
* The engine's TLS private key lives in the runtime directory: `.run/` in a checkout, and
  `~/Library/Application Support/ChatBots/` for an installed build, which is where the released
  app runs from. Both are private to the user and neither is committed. `RunDirectory.resolve`
  is the one answer to which one applies, and it chooses `.run` only when the directory really
  holds a `Package.swift` — so this bullet used to be wrong for exactly the shipped case.

## Supported versions

Only `main` is supported. There are no releases or long-lived branches; fixes land on `main`
and the wiki records what is known to be open.
