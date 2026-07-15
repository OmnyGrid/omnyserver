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
  --api-token api-secret \
  --grant alice:admin-token:admin \
  --grant node-account:node-token:node
```

The Hub serves **one TLS port**. Nodes upgrade to a WebSocket on
`wss://…:8443/node`; the REST API, `/healthz` and `/metrics` are on
`https://…:8443`. Only 8443 needs to be open.

Add `--shell` and the same port also brokers [OmnyShell](https://github.com/OmnyGrid/omnyshell)
sessions on `wss://…:8443/shell`, sharing the Hub's `--grant` credentials. Nodes
join that fleet either with `omnyserver node start --with-shell` (one process,
one service unit) or as a standalone `omnyshell` node/service pointed at the
shell mount.

Use `--node-path` to mount the node channel somewhere other than `/node` (it
must match the agents' `--hub` path).

**AI for the web dashboard.** The dashboard's in-terminal `:ai` (and `:ide`)
agent runs its provider calls *through the Hub*, so no browser needs an API key.
Configure the Hub's provider once:

```sh
omnyserver ai config --provider anthropic --key -   # hidden prompt; writes ~/.omnyserver/ai.yaml (600)
omnyserver ai show                                  # verify (key masked)
omnyserver ai test                                  # live provider check
```

Then run the Hub with `--shell` (the broker that serves it). The key stays on
the Hub — the browser only learns the provider/model and forwards requests for
the Hub to sign. It can also come from `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` /
`GEMINI_API_KEY`. Without a config, `:ai` falls back to a key the operator types
into the dashboard's own Settings.

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
dart run bin/omnyserver.dart nodes list      --api https://hub:8443 --ca certs/ca.crt --token api-secret
dart run bin/omnyserver.dart node status worker-01 --api https://hub:8443 --ca certs/ca.crt --token api-secret
dart run bin/omnyserver.dart formula run docker worker-01 --action verify --api https://hub:8443 --ca certs/ca.crt --token api-secret
dart run bin/omnyserver.dart preset apply docker-host.json worker-01 --api https://hub:8443 --ca certs/ca.crt --token api-secret
```

`--token api-secret` is the Hub's master API token: one secret shared by every
operator, and the audit trail can only call it `api`. Give each operator a grant
instead and let them present it with `--principal`:

```sh
# hub start … --grant alice:admin-token:admin
dart run bin/omnyserver.dart node status worker-01 \
  --api https://hub:8443 --ca certs/ca.crt \
  --principal alice --token admin-token
```

The Hub verifies the pair against the same grant store the node channel uses, so
the audit trail names `alice`, and her roles — not the token she holds — decide
what she may do. Revoking one operator is then dropping one `--grant`, and a
node's grant (`node-account`, role `node`) is refused by the API outright: the
`Authorizer` is fail-closed and reserves it for `admin`.

## 5. Run Hub/agent as an OS service

Install the Hub or an agent as a native service — systemd on Linux, launchd on
macOS, the Task Scheduler on Windows — so it starts at boot and is restarted if
it dies. `service install` takes the same flags as `hub start` / `node start` and
bakes this executable plus those flags into the service definition; there is no
separate daemon and no config file.

```sh
sudo omnyserver service install hub --system \
  --tls-dir /etc/letsencrypt/live/hub.example.com \
  --api-token "$API_TOKEN" \
  --grant node-account:node-token:node \
  --cors-origin https://dashboard.example.com

omnyserver service status hub          # running
omnyserver service info   hub          # the parameters, and the command the OS runs
```

The full set: `install`, `reinstall`, `reconfigure`, `uninstall`, `start`,
`stop`, `restart`, `status`, `info`. Two matter after day one:

- `service reconfigure hub --cors-origin …` re-applies changed flags to the
  installed service, preserving its running state.
- `service reinstall hub` refreshes the executable while keeping the config it
  was installed with — how a fleet picks up a new release.

`--dry-run` prints the generated unit/plist without touching the system.

**Scope.** The default is a user service (no elevation). `--system` installs
machine-wide and needs root (Linux/macOS) or Administrator (Windows); `install`
warns if you ask for one and are not the other. A Linux *user* service runs under
`systemctl --user`, which stops at logout unless lingering is enabled — `install`
tries to enable it and prints `sudo loginctl enable-linger <user>` if it cannot.

**Data.** `--data-dir` names one root holding everything: credentials and
identity at the top, the Hub's fleet data (nodes, audit, metrics, desired state,
issued grants) under `hub/`. It defaults to `/var/lib/omnyserver` under
`--system` and `~/.omnyserver` otherwise. A service persists by default; pass
`--ephemeral` for a Hub that keeps nothing.

**Secrets.** Flags become part of the service definition, so `--token`,
`--api-token` and `--grant` end up in a file readable by the installing user.
Restrict it, or keep secrets out of the unit — on Linux, `dart_service_manager`
supports systemd's `EnvironmentFile=`.

> Not to be confused with **remote service control** (`ServiceControl`,
> `NodeServiceHandler`): that is the Hub telling a node to manage some service
> *on that machine* — fleet management. This section is about OmnyServer
> supervising itself.

## Persistence

Choose a `NodeRepository`/`AuditRepository`/`MetricRepository` backend when
constructing `HubConfig`:

- `MemoryNodeRepository` — ephemeral (default).
- `JsonNodeRepository('/var/lib/omnyserver')` — human-readable files.
- `SqliteStore.open('/var/lib/omnyserver/omny.db')` — durable single file.

## Observability

- Prometheus scrape target: `https://hub:8443/metrics`.
- Recent events: `GET /api/v1/events`. Audit: `GET /api/v1/audit`.
- OpenAPI: `GET /api/v1/openapi.json`.
