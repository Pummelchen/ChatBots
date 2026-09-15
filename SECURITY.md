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
  `127.0.0.1` and are not reachable from the network. The website is reachable from another
  device only when you start it that way, through Caddy.
* **A share link is local.** `/s/<id>` is served by the engine that holds the conversation.
  There is no upload and no hosting.
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
  writing the conversation to that place. Any value other than `0`, `false`, `no` or the empty string
  turns it on.

## The local trust boundary, stated honestly

The desktop app reaches the engine over WebTransport with the transport library's
`.localDevelopmentSelfSigned` policy. That is a loopback-only bypass of platform certificate
validation: **the engine's fingerprint is reported and logged but not enforced.** A malicious
process already running as your user could present its own certificate and be accepted. It is
accepted because the alternative is no encrypted local channel at all, and because a process
that can run as you can read the engine's files directly. See the comment at the top of
`Sources/ChatBotsCore/WebTransportClient.swift`.

## Keys

* **No key is compiled into this repository, and none may be.** A key in the source is a key in
  every clone; this project is public. One was, early on, and had to be revoked — which is why
  `TavilyKeyTests` now fails if a key appears in `TavilyClient.swift` again.
* Keys are read from the environment (`TAVILY_API_KEY`, `DEEPSEEK_API_KEY`) or from
  `.secrets.env` at the project root. That file is gitignored and must never be committed.
* The engine's TLS private key lives in `.run/`, which is also gitignored.

## Supported versions

Only `main` is supported. There are no releases or long-lived branches; fixes land on `main`
and the wiki records what is known to be open.
