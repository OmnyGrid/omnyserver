# Deployment Guide

## 1. Generate TLS certificates

```sh
dart run bin/omnyserver.dart cert gen --out certs
# or: tool/gen-dev-certs.sh
```

This writes `certs/ca.crt` (trusted by nodes), `certs/server.crt` (Hub chain)
and `certs/server.key` (Hub key).

## 2. Start the Hub

```sh
./run-hub.sh
# or explicitly:
dart run bin/omnyserver.dart hub start \
  --host 0.0.0.0 --port 8443 \
  --cert certs/server.crt --key certs/server.key \
  --api-port 8080 --api-token api-secret \
  --grant alice:admin-token:admin \
  --grant node-account:node-token:node
```

The Hub listens on `wss://…:8443`; its REST API and `/metrics` on `:8080`.

## 3. Start a Node agent (on each managed server)

```sh
dart run bin/omnyserver.dart node start \
  --hub wss://hub.example.com:8443 \
  --id worker-01 \
  --principal node-account --token node-token \
  --ca certs/ca.crt
```

The agent connects, registers, reports live status/capabilities, executes
dispatched operations, and reconnects automatically if the link drops.

## 4. Operate via the CLI (through the HTTP API)

```sh
dart run bin/omnyserver.dart nodes list      --api http://hub:8080 --token api-secret
dart run bin/omnyserver.dart node status worker-01 --api http://hub:8080 --token api-secret
dart run bin/omnyserver.dart formula run docker worker-01 --action verify --api http://hub:8080 --token api-secret
dart run bin/omnyserver.dart preset apply docker-host.json worker-01 --api http://hub:8080 --token api-secret
```

## 5. Run Hub/agent as an OS service

`ServiceController` wraps `dart_service_manager` to install OmnyServer under
systemd / launchd / Windows Service Manager (install, start, stop, restart,
uninstall, auto-start).

## Persistence

Choose a `NodeRepository`/`AuditRepository`/`MetricRepository` backend when
constructing `HubConfig`:

- `MemoryNodeRepository` — ephemeral (default).
- `JsonNodeRepository('/var/lib/omnyserver')` — human-readable files.
- `SqliteStore.open('/var/lib/omnyserver/omny.db')` — durable single file.

## Observability

- Prometheus scrape target: `http://hub:8080/metrics`.
- Recent events: `GET /api/v1/events`. Audit: `GET /api/v1/audit`.
- OpenAPI: `GET /api/v1/openapi.json`.
