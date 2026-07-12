# OmnyServer Protocol

All Hub↔Node traffic is WebSocket-on-TLS (`wss`). There is no plaintext mode.
Serialization is hand-written JSON (no code generation).

The control plane is [omnyhub](https://pub.dev/packages/omnyhub)'s: registration,
heartbeats, discovery, request/response RPC and one-way pushes are omnyhub
messages, carried by `NodeGateway` (Hub) and `NodeRuntime` (node). OmnyServer
adds two things on top — an authentication handshake, and an operation
vocabulary.

## Endpoint

The Hub serves one TLS listener. Nodes upgrade to a WebSocket on
`HubConfig.nodeMount` (default `/node`); the REST API and `/metrics` are served
over HTTPS on the same host and port.

```
wss://hub.example.com:8443/node      ← node control channel
https://hub.example.com:8443/api/v1  ← REST API
```

## Handshake

Before the control plane starts, the Hub authenticates the connection in-band.
This is OmnyServer's own exchange, run by a `ConnectionAuthenticator` on the Hub
and `NodeConfig.onHandshake` on the node — both operating on the raw connection,
which is why it can carry a challenge/response round trip that an HTTP upgrade
cannot.

```
Node                          Hub
 │ ── Hello(role, version) ──► │
 │ ◄── AuthChallenge(nonce) ── │   32 random bytes, single use
 │ ── AuthSubmit(credential) ► │   a token, or the nonce signed with Ed25519
 │ ◄──── AuthOk / AuthFail ─── │
```

`ProtocolVersion` is negotiated in `Hello`; an incompatible **major** version is
rejected with a `ProtocolErrorMessage` and the connection is closed. An
`AuthFail` is terminal: the agent stops rather than reconnecting, because a
rejected credential is not fixed by retrying.

These six messages (`Hello`, `AuthChallenge`, `AuthSubmit`, `AuthOk`, `AuthFail`,
`ProtocolErrorMessage`) are the whole of `ControlMessage`. Everything after the
handshake is omnyhub's.

## Control plane (omnyhub)

```
Node                          Hub
 │ ── register(descriptor) ──► │   authorized, then persisted and announced
 │ ◄── registered(hubId, ms) ─ │   the Hub advertises the heartbeat cadence
 │ ── heartbeat(seq, status) ─►│   periodic; carries a live NodeStatus payload
 │ ◄── heartbeat_ack(seq) ──── │
 │ ◄── request(action, …) ──── │   Hub invokes an operation on the node
 │ ── response(ok, payload) ──►│
 │ ── notify(action, payload) ►│   one-way push: status reports, log batches
```

OmnyServer's full node descriptor (platform profile, structured capabilities,
uid) travels as JSON in omnyhub's `NodeDescriptor.attributes`; capability names
and labels are mirrored into omnyhub's own fields so its discovery works.

Registration is **authorized**, not merely authenticated: the Hub consults its
`Authorizer` with the claimed node id as the target. The default policy grants
`node.register` to the `node` role, so a node credential can enrol a node and
nothing else.

A node that disconnects or times out is **retained** in the registry, marked
offline, so its history and last-known descriptor survive.

## Operations

Operations ride as the `action` + `payload` of an omnyhub `NodeRequest`
(call/response) or `NodeNotify` (one-way). omnyhub owns the envelope,
correlation, timeout and failure-on-disconnect; OmnyServer owns the vocabulary.

| `action` | Direction | Payload → Response |
|---|---|---|
| `op.command.request` | Hub → node | `CommandRequest` → `CommandResult` |
| `op.formula.run` | Hub → node | `FormulaRun` → `FormulaRunResult` |
| `op.preset.apply` | Hub → node | `PresetApply` → `PresetApplyResult` |
| `op.service.control` | Hub → node | `ServiceControl` → `ServiceControlResult` |
| `op.node.control` | Hub → node | `NodeControl` → `OperationAck` |
| `node.status` | node → Hub | `StatusReport` (one-way) |
| `node.logs` | node → Hub | `LogBatch` (one-way) |

These action strings are the wire contract; they must stay stable.

The payloads keep a `requestId` field. It duplicates the envelope's correlation
id and the transport no longer reads it, but it is part of the handler signatures
applications implement and of the JSON the REST API returns.

## Liveness

The Hub advertises the heartbeat cadence at registration
(`HubConfig.heartbeatInterval`) and nodes honour it — a fleet's liveness budget
belongs to the Hub. A node that goes silent for `HubConfig.heartbeatTimeout` is
marked offline.

Status rides the heartbeat as a payload rather than as its own periodic message.
A status provider that throws or stalls does not delay or suppress the beat:
liveness never depends on telemetry.
