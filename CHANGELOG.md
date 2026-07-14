## 0.6.0

The Hub becomes callable from a browser. This is the foundation for the
OmnyServer Web dashboard: the same `HubApiClient` the CLI drives the Hub with now
compiles to JavaScript and runs on a page.

```sh
omnyserver hub start --cert certs/server.crt --key certs/server.key \
                     --api-token api-secret --grant alice:admin-token:admin \
                     --cors-origin https://dashboard.example.com
omnyserver whoami --api https://hub:8443 --principal alice --token admin-token
```

### Added

- **`lib/omnyserver_client_web.dart`** — a browser-safe barrel: the REST client
  plus the entities it decodes (`NodeDescriptor`, `NodeStatus`, `OmnyEvent`,
  `AuditEntry`, …). A web app imports this and gets the *same* `fromJson` the Hub
  encodes with, so there is no second, drifting copy of the wire format.

  `test/unit/web_barrel_dart_io_free_test.dart` walks the barrel's import graph
  and fails if `dart:io` reappears anywhere in it. That is not fussiness:
  `dart2js` emits **no output at all** for an entrypoint that reaches an
  unsupported SDK library, so the build appears to succeed and the page is simply
  blank.

- **An HTTP transport seam.** `HubApiClient` now takes an `ApiTransport`:
  `IoApiTransport` (`dart:io`'s `HttpClient`) on the VM, `FetchApiTransport`
  (`fetch`) in a browser, or a fake in a test. TLS options moved onto the VM
  transport, where they belong — a browser owns its own TLS stack and cannot be
  handed a `SecurityContext` or told to accept a bad certificate.

- **`hub start --cors-origin <origin>`** (repeatable) and `HubConfig.corsOrigins`.
  A web dashboard is *always* a different origin from the Hub — in production and
  in development alike (`webdev` on `:8080`, Hub on `:8443`) — so without this the
  browser blocks every response and the app sees only network errors. Empty by
  default: a Hub with no browser client is unchanged, and no origin is trusted by
  accident.

  It is installed with `OmnyServerHub.useOuter` (new), *outside* the error mapper
  and authentication. Both matter. A `401`, `404` or `500` is rendered above
  ordinary middleware, so CORS mounted there could never stamp one — and a
  response a browser is not allowed to read arrives as an opaque network error,
  not as "your token is wrong". And a preflight carries no credentials by
  specification, so an authenticator that saw it first would reject it and no call
  would ever succeed.

- **`GET /api/v1/whoami`** and **`omnyserver whoami`** → `{principal, roles,
  authenticated}`. A client cannot answer either question for itself: it cannot
  tell a valid token from an invalid one until the first real call fails, long
  after the login form is gone, and it cannot know which roles it holds, so it
  would have to offer every action and let the Hub refuse half of them.

### Fixed

- `POST /nodes/{id}/formula` was missing from the OpenAPI document, so a client
  generated from it would silently lack the ability to run formulas.

---

## 0.5.0

Operators get an identity. The CLI's API commands now take `--principal`
alongside `--token`, presenting a Hub **grant** — the credential nodes already
use — instead of the Hub-wide master API token.

```sh
# hub start … --grant alice:admin-token:admin
omnyserver node status worker-01 --api https://hub:8443 \
                                 --principal alice --token admin-token
```

### Added

- `--principal` on every CLI command that calls the Hub API (`node status`,
  `node restart`, `nodes list`, `formula run`, `preset apply`). Paired with
  `--token`, it is verified against the same grant store the node control channel
  authenticates against: the principal and its roles come from the grant, not
  from the caller. `HubApiClient` sends the pair as `x-omny-principal` plus the
  bearer token.
- `api.access`, the action a grant must be authorized for to use the HTTP API.
  `RoleBasedAuthorizer` leaves it unmapped and so fail-closed on `admin`, which
  is what stops a node's own grant (role `node`) from operating the fleet through
  the API it can authenticate to — it gets a `403`.

### Changed

- The API's audit trail records the principal the Hub **verified** rather than
  the one the caller asserted in `x-omny-principal`. With the master API token
  the header still stands in as attribution (that token is already `admin`, so
  there is nothing to escalate); with a grant it is ignored in favour of the
  authenticated identity.
- The master API token is compared in constant time, as grant tokens already
  were.

Existing setups are unaffected: `--token api-secret` alone behaves exactly as
before, and an API with no `--api-token` stays open.

## 0.4.0

Certificates that renew themselves. The Hub can now take its TLS material from a
LetsEncrypt-style directory and reload it when it is renewed — matching
`omnyshell hub start --tls-dir`.

```sh
omnyserver hub start --tls-dir /etc/letsencrypt/live/hub.example.com \
                     --api-token api-secret --grant node-account:node-token:node
```

### Added

- `hub start --tls-dir <dir>`: reads `fullchain.pem` + `privkey.pem` from the
  directory instead of `--cert`/`--key`. The files are re-checked periodically
  and, when a renewal changes them, the Hub rebinds its listener with the fresh
  certificate — no restart, with established connections draining on the old
  listener. Passing `--tls-dir` together with `--cert`/`--key` is an error, and
  the Hub still refuses to start without one of the two (no insecure mode).
- `HubConfig.tlsDirectory` and `HubConfig.tlsReloadInterval`, the embedded
  equivalent. Exactly one of `securityContext` or `tlsDirectory` must be given.

### Changed

- `HubConfig.securityContext` is now nullable and no longer `required` (a
  `tlsDirectory` may take its place). Existing code that passes a
  `securityContext` is unaffected.

## 0.3.1

Dependency maintenance — no API or behaviour changes.

### Changed

- Widened the dependency floors to the current releases: `omnyhub` 1.5.1,
  `omnyshell` 1.56.1, `sqlite3` 2.9.4, `meta` 1.19.0 and `path` 1.9.1.

## 0.3.0

One Hub, two kinds of node. An OmnyServer Hub can now also serve
[OmnyShell](https://pub.dev/packages/omnyshell) nodes — same port, same
certificate, same credentials — and one node process can be both an OmnyServer
agent and an OmnyShell node.

```sh
# Hub: three surfaces on one TLS port
omnyserver hub start --cert … --key … --shell
#   /node    → OmnyServer node control channel
#   /shell   → OmnyShell broker
#   /api/v1  → REST API

# Node: one process, both roles, one service unit
omnyserver node start --hub wss://hub:8443 --id worker-01 --token … --with-shell

# …or attach a standalone OmnyShell node to the same Hub:
omnyshell node start --hub wss://hub:8443/shell --id worker-01 --token …
omnyshell exec worker-01 'uptime' --hub wss://hub:8443/shell …
```

### Added

- **`--shell` / `--shell-path` on `hub start`** mount an OmnyShell broker on the
  Hub's listener (`ShellHub`, exported from `omnyserver_hub.dart`). It shares the
  Hub's `--grant` token table, so one credential set serves both fleets and there
  is nothing extra to provision. Authorization stays OmnyShell's: `admin` may open
  a session on any node, other roles only on nodes whose `allow-roles` label names
  them.
- **`--with-shell` / `--shell-path` / `--shell-label` on `node start`** also run an
  OmnyShell node in the same process — one binary, one service unit, one
  supervision target. It uses the same PTY backend `omnyshell node start` does.
- `HubConfig.shellMount` (default `/shell`), and a `connectionAuthenticator`
  parameter on `OmnyServerHub.registerService()`.

### Fixed

- **OmnyServer's node handshake was imposed on every WebSocket mount.** It was
  registered hub-wide, and omnyhub resolves a route's connection authenticator as
  `route.connectionAuthenticator ?? hubWide` — a route's `null` means *inherit*,
  not *none*. Any co-hosted WebSocket service would therefore have had OmnyServer's
  handshake run against it: a peer speaking its own protocol would have had its
  frames eaten by a handshake meant for someone else and been rejected after a
  10-second timeout. The handshake is now attached to the node channel's route
  alone. (Latent before this release, since nothing else was mounted; it is what
  made co-hosting possible.)

### Changed

- Depends on `omnyshell ^1.56.0`.
- `run-hub.sh` now forwards extra flags to the CLI, so `./run-hub.sh --shell`
  works. It silently dropped them before.

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
