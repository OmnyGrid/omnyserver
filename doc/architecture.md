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
| `infrastructure` | Technology adapters | WSS transport, authenticators, monitors, capability detectors, persistence (memory/JSON/SQLite), HTTP API, metrics |
| `protocol` | Wire contract | `ControlMessage` + codec, `OmnyConnection` port |
| `shared` | Cross-cutting utilities | errors, JSON helpers, `Clock`, id generator |

## Public libraries (`lib`)

- `omnyserver.dart` — shared core (models, protocol, contracts).
- `omnyserver_hub.dart` — Hub runtime + server infra + persistence + HTTP API + metrics.
- `omnyserver_node.dart` — Node agent + monitors + capability detectors + formula engine + service management.
- `omnyserver_cli.dart` — the CLI as a library (`buildRunner`, `HubApiClient`).

## Key principles

- **Everything in the CLI is an API.** CLI commands call the same public
  runtimes / HTTP API any other client would.
- **Ports & adapters.** `OmnyConnection` is the transport port; WSS is the only
  adapter today, but gRPC/QUIC/a message bus can implement the same contract.
- **Pluggable persistence.** `NodeRepository` and friends have in-memory,
  JSON-directory and SQLite implementations behind one interface.
- **Idempotent convergence.** Formulas report `changed`, presets compose them,
  and `StateReconciler` drives a node toward a desired state.
- **Fail-open transport, fail-closed protocol.** Undecodable frames are dropped;
  authorization and validation deny by default.
