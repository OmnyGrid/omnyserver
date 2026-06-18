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
