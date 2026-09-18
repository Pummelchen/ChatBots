# ChatBots audit — open work

Generated from `AUDIT/ledger.json` by `AUDIT/render-ledger.py`; edit the JSON, not this file.
**107 recorded · 106 closed · 0 open · 1 awaiting a decision**

Closed tasks stay in the JSON as the audit record and are not repeated here.

## Open

None.

## Awaiting a decision

| # | task | sev | title | owner | situation | options |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | AUDIT-0058 | S2 | The app adopts any process answering on 7790 without verifying it, then hands it every Keychain API key | repository owner (Pummelchen) | the app adopts any process answering on 127.0.0.1:7790 and then sends it every Keychain API key; the client transport accepts a self-signed loopback peer without fingerprint enforcement, so a same-user process can impersonate the engine. Fixing it needs a trust mechanism between the app and the engine, which is a new cross-project contract (two products, one secret). TRIED: reviewed EngineSupervisor, WebTransportClient and SECURITY.md; confirmed the probe uses .localDevelopmentSelfSigned and that applyAPIEndpoints sends the keys. | (1) the engine writes a random session token to .run/ (0600) at startup and the app must see it echoed before it sends any key; (2) the app never adopts an existing engine and always launches its own, refusing to start when the port is taken. Both change the app/engine contract and need the owner's choice. |

