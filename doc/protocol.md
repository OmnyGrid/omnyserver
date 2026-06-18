# OmnyServer Protocol

All Hub↔Node and Hub↔Client traffic is WebSocket-on-TLS (`wss`). There is no
plaintext mode. Frames are strongly typed; serialization is hand-written JSON
(no code generation).

## Frames

An `OmnyFrame` is one of:

- **ControlFrame** — a UTF-8 JSON text frame carrying a `ControlMessage`.
- **DataFrame** — a binary frame for high-volume streaming (logs, metric
  bursts). Layout: `[opcode:1][channel:uint32 BE][payload…]`.

`FrameCodec` encodes/decodes both; `ControlMessageCodec` maps a message's
`type` discriminator to its decoder.

## Handshake

```
Node                         Hub
 │ ── Hello(role, version) ──► │
 │ ◄── AuthChallenge(nonce) ── │
 │ ── AuthSubmit(credential) ► │   (token, or signed nonce for public-key)
 │ ◄──── AuthOk / AuthFail ─── │
 │ ── NodeRegister(descriptor)►│
 │ ◄─── NodeRegistered ─────── │
 │ ── NodeHeartbeat(status) ──►│   (periodic; carries a live NodeStatus)
 │ ◄── NodeHeartbeatAck ────── │
```

`ProtocolVersion` is negotiated in `Hello`; an incompatible major version is
rejected with a `ProtocolErrorMessage`.

## Message families

| Family | Messages |
|--------|----------|
| Handshake/auth | `Hello`, `AuthChallenge`, `AuthSubmit`, `AuthOk`, `AuthFail` |
| Lifecycle | `NodeRegister`, `NodeRegistered`, `NodeHeartbeat`, `NodeHeartbeatAck` |
| Monitoring | `StatusReport`, `LogBatch` |
| Keepalive | `Ping`, `Pong` |
| Discovery | `NodeListRequest`, `NodeListResponse` |
| Operations | `CommandRequest`/`CommandResult`, `FormulaRun`/`FormulaProgress`/`FormulaRunResult`, `PresetApply`/`PresetApplyResult`, `ServiceControl`/`ServiceControlResult`, `NodeControl`/`OperationAck` |
| Errors | `ProtocolErrorMessage` |

Operations carry a `requestId` so the Hub can correlate a node's reply with the
in-flight request (`OmnyServerHub` keeps a pending-request map).
