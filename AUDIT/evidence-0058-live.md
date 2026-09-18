# AUDIT-0058 — the session token, verified against a running engine

The unit tests prove the rules; these are the observations from an actual `chatbots-cli` process,
because a control that is only asserted in tests is a control nobody has watched work. Commit
`eab25b4`, `./.build/debug/chatbots-cli`, run directory `/tmp/ab-token-check`.

## The token is written, at the right mode, before the port answers

```
$ ls -la /tmp/ab-token-check/
drwx------@   5 node1  wheel    160  .
-rw-------@   1 node1  wheel     64  session-token
-rw-r--r--@   1 node1  wheel   1135  webtransport-cert.pem
-rw-------@   1 node1  wheel   1704  webtransport-key.pem

$ stat -f 'mode=%Sp bytes=%z name=%N' /tmp/ab-token-check/session-token
mode=-rw------- bytes=64 name=/tmp/ab-token-check/session-token

$ grep -cE '^[0-9a-f]{64}$' /tmp/ab-token-check/session-token
1
```

The run directory came out `drwx------` (0700) and the file `-rw-------` (0600) — not the umask's
answer, which is the point of the explicit `fchmod` and `setAttributes`. 64 characters is 32 bytes of
hex, and the engine was already logging its certificate fingerprint and listening on the transport
when this was taken, so the token exists before the port is useful.

## The unauthenticated HTTP surface cannot learn it

Run with `--transport http --port 17796` against the same run directory:

```
POST /api/identify       -> HTTP 404
POST /api/identity       -> HTTP 404
POST /api/session-token  -> HTTP 404
GET  /api/state          -> HTTP 200
token present in /api/state: 0
```

`/api/state` answers 200, so the API is up and reachable — and the 64-character token does not appear
in its body. This is the invariant that matters most: the website's API is unauthenticated and, through
Caddy, LAN-reachable (an accepted risk, AUDIT-0018/0077). If the echo had been added to `APISnapshot`,
this control would have handed the token to every device on the network.

## What is not shown here

The refusal path — an engine that answers but echoes the wrong token, or no token at all, is not
adopted and is sent no Keychain key — is covered by tests rather than by this run, because it needs a
process deliberately squatting the port. The tests are `EngineIdentityTests` in `Tests/ChatBotsAppTests`
("Only the token this run wrote is accepted", "With no token on disk, nothing is adopted", "The refusal
names the port and promises no credentials") and `SessionTokenTransportTests` in `Tests/ChatBotsCoreTests`.
