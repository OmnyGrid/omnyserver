# omnyserver

[![pub package](https://img.shields.io/pub/v/omnyserver.svg?logo=dart&logoColor=00b9fc)](https://pub.dev/packages/omnyserver)
[![Null Safety](https://img.shields.io/badge/null-safety-brightgreen)](https://dart.dev/null-safety)
[![Dart CI](https://github.com/OmnyGrid/omnyserver/actions/workflows/dart.yml/badge.svg?branch=master)](https://github.com/OmnyGrid/omnyserver/actions/workflows/dart.yml)
[![GitHub Tag](https://img.shields.io/github/v/tag/OmnyGrid/omnyserver?logo=git&logoColor=white)](https://github.com/OmnyGrid/omnyserver/releases)
[![New Commits](https://img.shields.io/github/commits-since/OmnyGrid/omnyserver/latest?logo=git&logoColor=white)](https://github.com/OmnyGrid/omnyserver/network)
[![Last Commits](https://img.shields.io/github/last-commit/OmnyGrid/omnyserver?logo=git&logoColor=white)](https://github.com/OmnyGrid/omnyserver/commits/master)
[![Pull Requests](https://img.shields.io/github/issues-pr/OmnyGrid/omnyserver?logo=github&logoColor=white)](https://github.com/OmnyGrid/omnyserver/pulls)
[![Code size](https://img.shields.io/github/languages/code-size/OmnyGrid/omnyserver?logo=github&logoColor=white)](https://github.com/OmnyGrid/omnyserver)
[![License](https://img.shields.io/github/license/OmnyGrid/omnyserver?logo=open-source-initiative&logoColor=green)](https://github.com/OmnyGrid/omnyserver/blob/master/LICENSE)

A **distributed server-orchestration platform** written in **pure Dart**. A
central **Hub** manages a fleet of **Node** agents — a cloud-like view of every
server's status, resources, capabilities, services and deployments, driven from
one place.

Nodes dial the Hub outbound over **WebSocket-on-TLS (`wss`)** — the same
identity-centric, NAT-friendly model as its sibling
[omnyshell][omnyshell]: you address servers by **node identity**, not
`host:port`. A node behind NAT needs no inbound port, and the Hub needs exactly
one: the node channel and the REST API share a single TLS listener.

```text
                       :8443 (TLS)
        ┌──────────────────┴──────────────────┐
        │  /node      → node control channel  │
        │  /shell     → OmnyShell broker      │
   ────►│  /api/v1    → REST API              │◄────  CLI / REST client
        │  /metrics   → Prometheus            │
        └──────────────────┬──────────────────┘
                          HUB
                ▲          ▲          ▲
              wss│       wss│       wss│      (outbound; NAT-friendly)
              Node       Node       Node
```

```sh
omnyserver cert gen --out certs
omnyserver hub start  --cert certs/server.crt --key certs/server.key \
                      --api-token api-secret --grant node-account:node-token:node
omnyserver node start --hub wss://hub:8443 --id worker-01 \
                      --principal node-account --token node-token --ca certs/ca.crt
omnyserver nodes list --api https://hub:8443 --ca certs/ca.crt --token api-secret
```

### Remote shell, from the same Hub

Add `--shell` and the Hub also brokers [OmnyShell][omnyshell] sessions — same
port, same certificate, same credentials. A node becomes shell-capable with
`--with-shell`, in the same process:

```sh
omnyserver hub start  … --shell
omnyserver node start … --with-shell --shell-label allow-roles=admin

omnyshell exec worker-01 'uptime' --hub wss://hub:8443/shell \
                                  --principal alice --token admin-token --ca certs/ca.crt
```

A standalone OmnyShell node or service can attach to the same Hub just as well —
point it at the shell mount:

```sh
omnyshell service install node --hub wss://hub:8443/shell --id worker-01 --token …
```

Everything is available both as **first-class Dart APIs** and as the
**`omnyserver` CLI** and a versioned **REST API** (`/api/v1`) ready for a future
Web UI. Runs on **Linux, macOS and Windows**.

Built on **[omnyhub][omnyhub]** — the transport, node registry, heartbeat
watchdog, RPC correlation and HTTP routing are the framework's, so OmnyServer is
only what is actually its own.

## API Documentation

See the [API Documentation][api_doc] for the full list of classes and APIs.

[api_doc]: https://pub.dev/documentation/omnyserver/latest/

## Features

- **Hub orchestrator** — node registration, discovery, authentication, live
  monitoring, audit and event aggregation, with a live model of every node.
- **Node agents** — connect, heartbeat, report status & capabilities, execute
  commands/formulas/presets, and reconnect automatically.
- **Live monitoring** — CPU, memory, storage, OS, processes and logs, designed
  for real-time dashboards.
- **Capability detection** — Docker, Podman, Dart, Python, Java, Node.js, Git,
  SSH, CUDA, Metal, OpenCL — detected dynamically.
- **Formulas & presets** — idempotent, cross-platform install/manage procedures,
  composed into presets, with desired-state reconciliation.
- **Service management** — install Hub/agent as systemd / launchd / Windows
  services via `dart_service_manager`.
- **Security** — token & Ed25519 public-key auth, role-based authorization,
  content-derived identity, audit log; RBAC/multi-tenant ready.
- **Persistence** — repository abstractions with in-memory, JSON-directory and
  SQLite backends (PostgreSQL/distributed ready).
- **HTTP API & metrics** — versioned REST API with OpenAPI, structured errors,
  and Prometheus/OpenTelemetry-ready `/metrics`, served on the Hub's own TLS port
  beside the node channel — one port to open, one certificate to manage.
- **Events** — `NodeConnected`, `HeartbeatReceived`, `FormulaFinished`,
  `PresetApplied`, … with subscriptions and streaming.
- **Remote shell** — the Hub can also broker [OmnyShell][omnyshell] sessions on
  the same port and credentials (`--shell`), and a node can be both an OmnyServer
  agent and an OmnyShell node in one process (`--with-shell`).

## Architecture

OmnyServer is a single package with role-based export libraries over a layered
`lib/src` (domain → application → infrastructure, plus protocol and shared).

```
lib/
  omnyserver.dart        core: models, protocol, contracts
  omnyserver_hub.dart    Hub runtime + server infra + persistence + HTTP API + metrics
  omnyserver_node.dart   Node agent + monitors + capabilities + formulas + services
  omnyserver_cli.dart    CLI as a library (buildRunner, HubApiClient)
  src/
    domain/         value objects, entities, Formula, auth & repository contracts, events
    application/    OmnyServerHub, NodeAgent, NodeFormulaService, EventAggregator
    infrastructure/ auth, monitors, capabilities, persistence, http, metrics
    protocol/       handshake messages + codec, operation payloads
    shared/         errors, json helpers, clock, ids
```

See [doc/architecture.md](doc/architecture.md), [doc/protocol.md](doc/protocol.md),
[doc/security.md](doc/security.md), [doc/formulas.md](doc/formulas.md) and
[doc/deployment.md](doc/deployment.md).

## Getting started

```yaml
dependencies:
  omnyserver: ^0.3.0
```

Or install the CLI:

```sh
dart pub global activate omnyserver
```

Supported platforms: **Linux**, **macOS**, **Windows**. Requires the Dart SDK
3.12+.

## Usage

### Quick start (embedded Hub + Node)

The fastest way to see the whole stack work is the embedded example, which
starts a Hub and a Node in one process and prints the node's live status:

```sh
dart run example/omnyserver_embedded_example.dart
```

```dart
final hub = OmnyServerHub(HubConfig(
  host: '127.0.0.1', port: 0,
  securityContext: SecurityContext()
    ..useCertificateChain(certs.serverCert)
    ..usePrivateKey(certs.serverKey),
  authenticator: TokenAuthenticator({
    'node-token': TokenGrant(principal: PrincipalId('node-account'), roles: {'node'}),
  }),
));
await hub.start();

final agent = NodeAgent(NodeAgentConfig(
  hubUri: Uri.parse('wss://127.0.0.1:${hub.port}'),
  nodeId: 'demo-node',
  credentials: const TokenCredentialProvider(principal: 'node-account', token: 'node-token'),
  securityContext: SecurityContext(withTrustedRoots: false)..setTrustedCertificates(certs.caCert),
  statusProvider: const SystemMonitor().snapshot,
  capabilityProvider: CapabilityScanner.standard().scan,
));
await agent.start();

// The node pushes a status snapshot as it registers, but it still has to reach
// the Hub — give it a moment before reading.
await Future<void>.delayed(const Duration(seconds: 1));

final status = hub.getStatus(NodeId('demo-node'));
print('${status?.cpu.coreCount} cores, ${status?.cpu.usagePercent}% used');
```

### Run a Hub

```sh
dart run bin/omnyserver.dart cert gen --out certs
./run-hub.sh
```

> The Hub only speaks `wss` and requires a certificate chain + key. Dart's TLS
> stack rejects a bare self-signed leaf, so `cert gen` builds a CA → leaf chain;
> nodes trust the CA with `--ca`.

With a real certificate (LetsEncrypt, cert-manager, a mounted secret), point the
Hub at the directory instead of the two files:

```sh
omnyserver hub start --tls-dir /etc/letsencrypt/live/hub.example.com \
                     --api-token api-secret --grant node-account:node-token:node
```

`--tls-dir` reads `fullchain.pem` + `privkey.pem` and re-checks them
periodically: when the certificate is renewed the Hub rebinds its listener with
the fresh one — no restart, and established connections drain on the old
listener. It replaces `--cert`/`--key`; passing both is an error.

### Run a Node

```sh
dart run bin/omnyserver.dart node start \
  --hub wss://hub:8443 --id worker-01 \
  --principal node-account --token node-token --ca certs/ca.crt
```

### Discover and operate (via the REST API)

```sh
omnyserver nodes list                 --api https://hub:8443 --ca certs/ca.crt --token api-secret
omnyserver node status  worker-01     --api https://hub:8443 --ca certs/ca.crt --token api-secret
omnyserver node restart worker-01     --api https://hub:8443 --ca certs/ca.crt --token api-secret
omnyserver formula run docker worker-01 --action verify --api https://hub:8443 --ca certs/ca.crt --token api-secret
omnyserver preset apply docker-host.json worker-01 --api https://hub:8443 --ca certs/ca.crt --token api-secret
```

The CLI's operational commands call the Hub's HTTP API — exactly the surface any
other client uses.

Every one of them takes either credential the Hub knows:

```sh
# The Hub's master API token — one shared secret, audited as "api".
omnyserver node status worker-01 --api https://hub:8443 --token api-secret

# Your own grant (--grant alice:admin-token:admin) — an identity the Hub
# verifies, so the audit trail names you and your roles decide what you may do.
omnyserver node status worker-01 --api https://hub:8443 \
                                 --principal alice --token admin-token
```

A grant's roles are checked against the Hub's `Authorizer` before it may touch
the API at all, and the fail-closed default reserves it for `admin` — so
`node-account`'s token connects nodes and nothing more, even if it leaks.

### Formulas and presets

Ask the Hub what nodes can actually do, rather than guessing into a free-text
box:

```sh
omnyserver formula list
# FORMULA     NAME              ACTIONS
# dart        Dart SDK          install, update, uninstall, verify
# docker      Docker            install, update, start, stop, restart, uninstall, verify
```

Save a preset on the Hub once, and apply it by id everywhere:

```sh
omnyserver preset save docker-host.json
omnyserver preset apply docker-host --label env=prod
```

A preset file is whatever copy *you* happen to have; a saved preset is the one
everybody agrees on. `preset apply` still accepts a file, for a one-off.

### Addressing the fleet

Label a node when it starts, then select on the label:

```sh
omnyserver node start --id web-01 --label env=prod --label role=web
omnyserver nodes list  --label env=prod
omnyserver nodes list  --offline                      # the ones wanting attention

omnyserver formula run docker --label env=prod --action verify   # every prod node
omnyserver preset apply docker-host.json --all
```

`formula run` and `preset apply` take one node, `--node` (repeatable), `--label`,
or `--all`, and report a result per node. A selector matching nothing is an
error, not a quiet success — "applied to 0 nodes" reads like it worked.

### Issuing credentials

Grants can be baked into the command line (`--grant alice:admin-token:admin`), or
issued at runtime and revoked without restarting the Hub:

```sh
omnyserver hub start … --data-dir /var/lib/omnyserver   # or the grants die with it
omnyserver grant add bob --role viewer --note 'read-only dashboard'
omnyserver grant list
omnyserver grant revoke <id>        # the next request with that token fails
```

**The Hub stores a hash, not the token.** It is printed once, when issued, and
cannot be shown again — so the Hub's storage is not a list of passwords, and a
lost token is replaced rather than recovered. That is what the grant id is for.

Issuing and revoking are `admin`-only, so an operator can run the fleet but not
mint itself an admin token.

> **`--data-dir` is not optional in production.** Without it the Hub keeps nodes,
> the audit trail, metrics, declared state *and issued credentials* in memory
> only, and forgets all of it when it stops.

### Desired state, and drift

Declare what a node is *supposed* to be, then ask — at any point later — whether
it still is:

```sh
omnyserver state set docker-host.json --label env=prod   # declare; runs nothing
omnyserver state diff --label env=prod                   # has it drifted?
omnyserver state reconcile --label env=prod              # make it true again
```

**Declaring is not applying.** `preset apply` runs steps and tells you they
succeeded; it cannot tell you anything a week later, after somebody logged into
the machine and changed something by hand. A declaration keeps answering:
`state diff` re-plans against what the node currently advertises, and an empty
plan means no drift.

`state reconcile` runs exactly what the plan says is outstanding, so a converged
node does nothing at all — idempotent, and safe on a timer. `state diff` exits
non-zero when anything has drifted, so it works as a check in a pipeline.

### Roles

| Role | May |
|---|---|
| `viewer` | read the API: fleet, live status, history, events, audit |
| `operator` | also act: restart, shut down, update, formulas, presets |
| `admin` | everything |
| `node` | enrol a node — and nothing else; it cannot reach the API at all |

So a read-only dashboard link is a `--grant bob:view-token:viewer`, and a leaked
node credential still cannot operate the fleet.

### Alerts

```sh
omnyserver hub start … --alert 'disk>90' --alert 'cpu>95 for 5m' \
                       --alert 'offline for 2m'
omnyserver alerts    # what is wrong right now; non-zero while anything is
```

Judged on the heartbeats the Hub already receives. `for 5m` is what separates an
alert from a twitch: a node at 95% CPU for one heartbeat is a build running, and
one at 95% for five minutes is a problem. An alert is announced once and resolved
when it clears.

There are no default rules — a tool that invents its own thresholds is a tool that
pages you at 3am about a disk it decided was too full.

Read a node's log without logging into it:

```sh
omnyserver node logs worker-01 -f
```

The Hub keeps a bounded tail (the last 500 lines per node, in memory) — for
looking at a machine that is misbehaving now. It is not the audit trail, and not
a substitute for shipping logs somewhere that keeps them. Nodes ship their log by
default (`node start --no-ship-logs` opts out).

Watch the fleet, and read a node's history:

```sh
omnyserver events --follow                      # tail -f for the fleet (SSE)
omnyserver node metrics worker-01 --since 1h    # CPU / memory / disk over time
omnyserver audit                                # who did what, as the Hub verified it
```

`node metrics` reads history the Hub has been recording on **every heartbeat**
all along — no extra configuration, and it works for any node that has been
connected long enough to report twice.

`omnyserver whoami` answers what the Hub makes of your credentials:

```sh
omnyserver whoami --api https://hub:8443 --principal alice --token admin-token
# principal: alice
# roles:     admin
```

### From a browser

The Hub's API is callable from a web app — that is what `omnyserver_web`, the
dashboard, is built on. Two things are needed, and both are needed:

```sh
omnyserver hub start --cert certs/server.crt --key certs/server.key \
                     --api-token api-secret --grant alice:admin-token:admin \
                     --cors-origin https://dashboard.example.com
```

- **`--cors-origin`** — a browser will not hand a page a cross-origin response
  unless the server says that origin may have it, and a dashboard is *always* a
  different origin than the Hub (in development too: `webdev` on `:8080`, Hub on
  `:8443`). Without it the app sees network errors and nothing else.
- **A publicly-trusted certificate**, or one trusted at the OS/browser level. The
  browser owns the TLS stack; there is no in-page `--insecure` to offer, and a
  self-signed Hub simply will not load.

Client code imports the browser-safe barrel, and drives the very same
`HubApiClient` the CLI does:

```dart
import 'package:omnyserver/omnyserver_client_web.dart';

final client = HubApiClient(
  Uri.parse('https://hub.example.com:8443'),
  principal: 'alice',
  token: 'admin-token',
);
final nodes = (await client.get('/nodes') as List)
    .map((n) => NodeDescriptor.fromJson((n as Map).cast()))
    .toList();
```

### HTTP API

Served over HTTPS on the Hub's own port, alongside the node control channel —
one TLS listener, two surfaces. Versioned under `/api/v1`:

| Method & path | Description |
|---------------|-------------|
| `GET /nodes` | list registered nodes |
| `GET /nodes/{id}` | node descriptor |
| `GET /nodes/{id}/status` | live status snapshot |
| `GET /nodes/{id}/capabilities` | advertised capabilities |
| `POST /nodes/{id}/restart` · `/shutdown` · `/update` | node control |
| `POST /nodes/{id}/formula` | run a formula action |
| `POST /presets/apply` | apply a preset to a node |
| `GET /events` · `/audit` | recent events / audit |
| `GET /openapi.json` | OpenAPI document |
| `GET /metrics` (root) | Prometheus exposition |

## How it works

OmnyServer is built on [omnyhub](https://pub.dev/packages/omnyhub): the
transport, node registry, heartbeat watchdog, RPC correlation and HTTP routing
are the framework's. What OmnyServer adds is what is actually its own — identity,
capability detection, formulas, presets, reconciliation, auditing and
persistence.

### Connection flow

1. A Node dials the Hub over `wss` at `/node` and sends `Hello`.
2. The Hub issues a challenge nonce; the Node answers with a token or a signed
   nonce. On success the Hub returns the resolved principal and roles.
3. The Node registers its descriptor (identity, platform, capabilities, labels).
   The Hub *authorizes* the registration — a node credential may enrol a node and
   nothing else — then adds it to the live registry and begins receiving
   heartbeats, each carrying a live status snapshot.
4. The Hub dispatches operations (formula, preset, restart, …) as RPCs over the
   same connection and correlates the replies.

### Security envelope

All transport is TLS. Authentication is pluggable (token / Ed25519 public key);
authorization is role-based and fail-closed; identity is content-derived; every
sensitive action is audited. See [doc/security.md](doc/security.md).

## The OmnyGrid ecosystem

OmnyServer is one of four packages sharing the same identity-centric,
NAT-friendly model — nodes dial a Hub outbound, and you address them by identity
rather than `host:port`.

| Package | What it does |
|---|---|
| **[omnyhub][omnyhub]** | The HUB framework everything below is built on: transport, routing, auth, node registry and control plane. |
| **omnyserver** (this) | Fleet orchestration — monitoring, capabilities, formulas, presets, desired-state reconciliation. |
| **[omnyshell][omnyshell]** | Remote shell — SSH-like sessions brokered to a node by identity. An OmnyServer Hub can host its broker (`--shell`). |
| **[omnydrive][omnydrive]** | File & git drive synchronization. |

[omnyhub]: https://github.com/OmnyGrid/omnyhub
[omnyshell]: https://github.com/OmnyGrid/omnyshell
[omnydrive]: https://github.com/OmnyGrid/omnydrive

## Roadmap

- Remote agent self-update and OS-update orchestration.
- Additional transports (gRPC, QUIC, message bus) behind omnyhub's `Transport`.
- PostgreSQL and distributed persistence backends.
- Richer reconciliation (dependency ordering, version comparison).
- Web UI on top of the REST API; RBAC / multi-tenant authorization.
- Kubernetes orchestration and AI-workload scheduling.

## Running the example and tests

```sh
dart pub get
dart analyze
dart test
dart run example/omnyserver_embedded_example.dart
```

# Author

Graciliano M. Passos: [gmpassos@GitHub][github].

[github]: https://github.com/gmpassos

## License

[Apache License - Version 2.0][apache_license].

[apache_license]: https://www.apache.org/licenses/LICENSE-2.0.txt
