# OmnyServer Architecture

OmnyServer is a distributed server-orchestration platform: a central **Hub**
manages a fleet of **Node** agents over WebSocket-on-TLS (`wss`). It follows a
clean, layered architecture so platform specifics never leak into the core and
future additions (Kubernetes, AI scheduling, a Web UI) slot in without rework.

```
            ┌─────────────────────────────────────────┐
            │                  HUB                      │
   CLI ───► │  NodeRegistry · OrchestrationEngine       │ ◄─── HTTP API (/api/v1)
   API ───► │  EventBus · AuditLog · Metrics            │ ◄─── Prometheus (/metrics)
            └──────────────┬──────────────┬─────────────┘
                    wss    │              │   wss
                 ┌─────────▼───┐     ┌────▼────────┐
                 │   Node A    │     │   Node B    │   …
                 │ monitors    │     │ monitors    │
                 │ capabilities│     │ capabilities│
                 │ formulas    │     │ formulas    │
                 └─────────────┘     └─────────────┘
```

## Layers (`lib/src`)

| Layer | Responsibility | Examples |
|-------|----------------|----------|
| `domain` | Pure model and contracts (no IO) | value objects, entities, `Formula`, `Authenticator`, repository interfaces, `OmnyEvent` |
| `application` | Use-case coordination | `OmnyServerHub`, `NodeAgent`, `NodeFormulaService`, `EventAggregator` |
| `infrastructure` | Technology adapters | authenticators, monitors, capability detectors, persistence (memory/JSON/SQLite), HTTP API, metrics |
| `protocol` | Wire contract | handshake `ControlMessage` + codec, operation payloads |
| `shared` | Cross-cutting utilities | errors, JSON helpers, `Clock`, id generator |

## Public libraries (`lib`)

- `omnyserver.dart` — shared core (models, protocol, contracts).
- `omnyserver_hub.dart` — Hub runtime + server infra + persistence + HTTP API + metrics.
- `omnyserver_node.dart` — Node agent + monitors + capability detectors + formula engine + service management.
- `omnyserver_cli.dart` — the CLI as a library (`buildRunner`, `HubApiClient`).

## Key principles

- **Everything in the CLI is an API.** CLI commands call the same public
  runtimes / HTTP API any other client would.
- **Built on omnyhub.** The transport, node registry, heartbeat watchdog, RPC
  correlation and HTTP routing are [omnyhub](https://pub.dev/packages/omnyhub)'s.
  Its `Connection` and `Transport` are the ports; WSS is the only adapter today,
  but gRPC/QUIC/a message bus can implement the same contract. OmnyServer owns
  what is actually its own: identity, capabilities, formulas, presets,
  reconciliation, auditing and persistence.
- **Pluggable persistence.** `NodeRepository` and friends have in-memory,
  JSON-directory and SQLite implementations behind one interface.
- **Idempotent convergence.** Formulas report `changed`, presets compose them,
  and `StateReconciler` drives a node toward a desired state.
- **Declare what a thing should be, not what to do to it.** A blueprint's
  resources carry an `ensure`, not an action. That single choice is what makes
  applying twice a no-op, makes drift detection the same comparison with the
  apply left off, and makes uninstall `ensure: absent` rather than its own code
  path.
- **Fail-open transport, fail-closed protocol.** Undecodable frames are dropped;
  authorization and validation deny by default.

## Blueprints

A **blueprint** is what a machine is; a **preset** is a piece it is made of.
Only a blueprint is assignable to a node, which is what earns the two names.

| Concept | Where | What it is |
|---|---|---|
| `Blueprint` | domain | The document: `includes` (preset ids), `vars`, `resources`. |
| `Resource` | domain | One declared thing, identified `type:name`, carrying an `Ensure`. |
| `BlueprintResolver` | application/hub | Flattens includes, substitutes vars, orders by `requires`, hashes. |
| `ResolvedBlueprint` | domain | What crosses the wire. Each resource names its origin. |
| `ResourceProvider` | domain | Reads and writes one resource type. The extension seam. |
| `NodeBlueprintService` | application/node | Reads, diffs, applies in order, writes the ledger. |
| `Ledger` | domain | What this system put on this machine. |

Two divisions of labour are deliberate:

- **The Hub resolves; the node plans.** Resolution happens once, so two nodes
  given "the same blueprint" are given the same bytes and the hash over them is
  a convergence check costing no round trip. Planning happens on the node
  because that is where the current state is — a plan assembled from what the
  Hub last heard is a plan assembled from intentions.
- **The node is the source of truth about the machine; the Hub caches the last
  thing it was told.** The moment the Hub is treated as authoritative you get a
  record of intentions mistaken for a record of facts.

Adding a resource type is writing a `ResourceProvider` — not touching the
format, the resolver, the protocol or the dashboard.
