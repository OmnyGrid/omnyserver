## 0.2.1

### Fixed

- **A node's status was unavailable for a full heartbeat interval after it
  registered.** Heartbeats are periodic, so the snapshot they carry is one
  interval away; on the default 15-second cadence the Hub reported *no status at
  all* for a node that had just come up (`GET /api/v1/nodes/{id}/status` answered
  `404` for ~18 seconds). The agent now pushes a snapshot on becoming ready — on
  every (re)registration — so status is live immediately.

  Introduced in 0.2.0: the pre-omnyhub agent sent an eager first heartbeat for
  exactly this reason, and omnyhub's `NodeRuntime` beats only on its timer. The
  test suite could not see it, because the harness uses a 200 ms cadence and a
  beat always landed before the assertion.

### Changed

- `run-hub.sh` still passed `--api-port`, removed in 0.2.0 when the REST API moved
  onto the Hub's TLS port. It now uses `--node-path`.
- README: refreshed for the single-port model (the quick-start could not run as
  written), full badge set, and an OmnyGrid ecosystem section.

## 0.2.0

Hosts OmnyServer on [omnyhub](https://pub.dev/packages/omnyhub) — the HUB
framework OmnyGrid already builds on. OmnyServer had grown its own copy of most
of it: a WebSocket transport, a node registry, a heartbeat watchdog, an RPC
correlation map, a reconnect policy and a hand-rolled HTTP router, several with
the same class names as omnyhub's. All of that is now omnyhub's, and roughly
1,500 lines of duplicated infrastructure are gone.

What stayed is what is actually OmnyServer's: identity, capability detection,
formulas, presets, desired-state reconciliation, auditing, events, metrics and
persistence.

### Breaking

- **The Hub and its REST API now share one TLS port.** Nodes upgrade to a
  WebSocket on `HubConfig.nodeMount` (default `/node`); operators call
  `/api/v1`, `/healthz` and `/metrics` on the same host and port, over the same
  certificate. The API is no longer a second, plaintext listener.
  - CLI: `--api-host` and `--api-port` are gone; `--node-path` is new.
  - `NodeAgentConfig` takes the Hub URL (`wss://hub:8443`) and fills in the
    mount itself via `nodeMount`. A URL that already carries a path is honoured
    as-is, for a node behind a path-rewriting proxy.
- **The hub↔node wire protocol is omnyhub's.** Registration, heartbeats,
  discovery and RPC are `register`/`heartbeat`/`query`/`request`/`notify`.
  OmnyServer's operations (`op.formula.run`, `op.node.control`, …) ride as the
  `action` + `payload` of an omnyhub `NodeRequest`/`NodeNotify`, so the operation
  vocabulary and every handler signature (`FormulaHandler`, `ServiceHandler`, …)
  are unchanged. A 0.1.0 node cannot talk to a 0.2.0 Hub.
- **The Hub advertises the heartbeat cadence and nodes honour it.** A fleet's
  liveness budget belongs to the Hub, so set `HubConfig.heartbeatInterval`;
  `NodeAgentConfig.heartbeatInterval` is now only a fallback for a Hub that
  advertises none.
- **`OmnyServerHub.registry` is omnyhub's `NodeRegistry`**, and `runFormula` /
  `applyPreset` return `FormulaRunResult` / `PresetApplyResult` instead of an
  untyped `ControlMessage`.
- Removed: `OmnyConnection`, `OmnyFrame`, `FrameCodec`, `WebSocketConnection`,
  `WsServerEndpoint` and OmnyServer's own `NodeRegistry` — omnyhub provides all
  of them. Also removed the parts of the protocol that had no production callers:
  the binary `DataFrame`/`DataOpcode` channel, `Ping`/`Pong`, `FormulaProgress`
  and `ControlMessage.channelId`.
- The REST wire contract is **unchanged** — same routes, status codes, bearer
  auth and `{"error":{"code","message"}}` envelope — so HTTP consumers and the
  CLI's API client are unaffected. Its contract test passes unmodified.

### Fixed

- **Node registration is now authorized, not merely authenticated.** `HubConfig`
  accepted an `Authorizer` and never called it, so any principal that could
  authenticate could register under — and thereby hijack — *any* node id. The
  Hub now authorizes `node.register` with the claimed id as the target, and
  `RoleBasedAuthorizer` grants it to the `node` role by default. A node
  credential can enrol a node and nothing else.
- **A node that failed authentication reconnected forever.** A revoked key is not
  fixed by retrying; the agent now treats an auth failure as terminal and stops.
- **A stale node's socket was leaked.** The heartbeat watchdog marked a node
  offline without closing its connection or cancelling its subscription, so a
  later close fired the disconnect path a second time and published a duplicate
  `NodeDisconnected`.
- **Node liveness could be lost to a slow metrics collector.** Status now rides
  the heartbeat as a payload; a status provider that throws or stalls leaves the
  beat itself untouched.

### Added

- `HubConfig.nodeMount`, `heartbeatInterval` and `requestTimeout` — the last of
  which was a hardcoded 30-second literal with no way to change it.
- `HttpApiServer.buildServices()` / `buildMiddleware()` — mount the REST API on
  any hub (that is how it shares the Hub's port), or keep `start()` to run it
  standalone.
- `NodeAgent.sendLogs()` and `reportStatus()` — one-way pushes to the Hub, on
  omnyhub's `notify`.

## 0.1.0

- Initial release of OmnyServer — a distributed server-orchestration platform.
- Hub runtime over WebSocket-on-TLS: node registration, authentication,
  heartbeat monitoring, live registry, audit log and event aggregation.
- Node agent: connect/auth/register/heartbeat with automatic reconnection;
  command, formula, preset, service and node-control handlers.
- Live monitoring (CPU, memory, storage, OS, processes) and dynamic capability
  detection (Docker, Podman, Dart, Python, Java, Node.js, Git, SSH, CUDA, Metal,
  OpenCL).
- Formula engine with idempotent built-in Docker and Dart formulas, presets, and
  capability-aware desired-state reconciliation.
- Pluggable persistence: in-memory, JSON-directory and SQLite repositories with
  a shared conformance suite.
- Token and Ed25519 public-key authentication, role-based authorization,
  content-derived identity (UID) and dev TLS certificate generation.
- Versioned REST HTTP API (`/api/v1`) with OpenAPI, auth/validation, structured
  errors, recent events/audit, and a Prometheus `/metrics` endpoint.
- `omnyserver` CLI (hub, node, nodes, preset, formula, cert) — every command
  backed by the same public APIs.
- Service management via `dart_service_manager` (systemd / launchd / Windows).
