# omnyserver

[![pub package](https://img.shields.io/pub/v/omnyserver.svg?logo=dart&logoColor=00b9fc)](https://pub.dev/packages/omnyserver)
[![Null Safety](https://img.shields.io/badge/null-safety-brightgreen)](https://dart.dev/null-safety)
[![Dart CI](https://github.com/OmnyGrid/omnyserver/actions/workflows/dart.yml/badge.svg?branch=master)](https://github.com/OmnyGrid/omnyserver/actions/workflows/dart.yml)
[![License](https://img.shields.io/github/license/OmnyGrid/omnyserver?logo=open-source-initiative&logoColor=green)](https://github.com/OmnyGrid/omnyserver/blob/master/LICENSE)

A **distributed server-orchestration platform** written in **pure Dart**. A
central **Hub** manages a fleet of **Node** agents — a cloud-like view of every
server's status, resources, capabilities, services and deployments, driven from
one place.

Nodes dial the Hub outbound over **WebSocket-on-TLS (`wss`)** — the same
identity-centric, NAT-friendly model as its sibling
[omnyshell](https://github.com/OmnyGrid/omnyshell): you address servers by
**node identity**, not `host:port`.

```text
            CLI / REST API
                  │
                  ▼
   Node ──wss──► HUB ◄──wss── Node ◄──wss── Node
```

```sh
omnyserver hub start  --cert certs/server.crt --key certs/server.key
omnyserver node start --hub wss://hub:8443 --id worker-01 --token … --ca certs/ca.crt
omnyserver nodes list
```

Everything is available both as **first-class Dart APIs** and as the
**`omnyserver` CLI** and a versioned **REST API** (`/api/v1`) ready for a future
Web UI. Runs on **Linux, macOS and Windows**.

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
  and Prometheus/OpenTelemetry-ready `/metrics`.
- **Events** — `NodeConnected`, `HeartbeatReceived`, `FormulaFinished`,
  `PresetApplied`, … with subscriptions and streaming.

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
    infrastructure/ wss transport, auth, monitors, capabilities, persistence, http, metrics
    protocol/       ControlMessage + codec, OmnyConnection (transport port)
    shared/         errors, json helpers, clock, ids
```

See [doc/architecture.md](doc/architecture.md), [doc/protocol.md](doc/protocol.md),
[doc/security.md](doc/security.md), [doc/formulas.md](doc/formulas.md) and
[doc/deployment.md](doc/deployment.md).

## Getting started

```yaml
dependencies:
  omnyserver: ^0.1.0
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

### Run a Node

```sh
dart run bin/omnyserver.dart node start \
  --hub wss://hub:8443 --id worker-01 \
  --principal node-account --token node-token --ca certs/ca.crt
```

### Discover and operate (via the REST API)

```sh
omnyserver nodes list                 --api http://hub:8080 --token api-secret
omnyserver node status  worker-01     --api http://hub:8080 --token api-secret
omnyserver node restart worker-01     --api http://hub:8080 --token api-secret
omnyserver formula run docker worker-01 --action verify --api http://hub:8080 --token api-secret
omnyserver preset apply docker-host.json worker-01 --api http://hub:8080 --token api-secret
```

The CLI's operational commands call the Hub's HTTP API — exactly the surface any
other client uses.

### HTTP API

Versioned under `/api/v1`:

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

### Connection flow

1. A Node dials the Hub over `wss` and sends `Hello`.
2. The Hub issues a challenge nonce; the Node answers with a token or a signed
   nonce. On success the Hub returns the resolved principal and roles.
3. The Node registers its descriptor (identity, platform, capabilities, labels);
   the Hub adds it to the live registry and begins receiving heartbeats.

### Security envelope

All transport is TLS. Authentication is pluggable (token / Ed25519 public key);
authorization is role-based and fail-closed; identity is content-derived; every
sensitive action is audited. See [doc/security.md](doc/security.md).

## Roadmap

- Remote agent self-update and OS-update orchestration.
- Additional transports (gRPC, QUIC, message bus) behind `OmnyConnection`.
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
