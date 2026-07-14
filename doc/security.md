# OmnyServer Security

## Transport

Every connection is WebSocket-on-TLS (`wss`). The Hub requires a server
certificate chain and private key; nodes and clients trust the issuing CA
(`--ca`). `onBadCertificate` is the escape hatch for certificate pinning or
self-signed dev certificates.

## Authentication

Pluggable `Authenticator`s verify a `Credential` against a per-connection
challenge nonce and resolve a `Principal`:

- **TokenAuthenticator** — bearer token matched in constant time against a grant
  store; the presented principal must match the token's grant.
- **PublicKeyAuthenticator** — the principal signs the Hub-issued nonce with an
  Ed25519 key; the `(principal, key)` pair must be in the authorized-keys store.
  A single-use nonce makes a captured signature non-replayable.
- **CompositeAuthenticator** — tries several authenticators in order.

### The HTTP API

`--api-token` gates `/api/v1` (without it the API is open, so it is for a
loopback-only Hub). Two credentials are accepted on it:

- **The API token** — a Hub-wide master key with no identity of its own. It
  always grants `admin`; the optional `x-omny-principal` header only names the
  caller in the audit trail, which costs nothing, as holding the master key
  already implies full access.
- **A grant** — `x-omny-principal: alice` plus the token from
  `--grant alice:admin-token:admin`, verified by the *same* `TokenAuthenticator`
  the node channel uses. Principal and roles come from the grant, never from the
  caller, so the identity in the audit trail is one the Hub established. The CLI
  sends this pair as `--principal` / `--token`.

Prefer grants: they are per-operator (revoking one is dropping one `--grant`),
they carry roles, and they cannot be forged by a caller who merely knows a name.

## Authorization

`RoleBasedAuthorizer` decides whether a `Principal` may perform an action
(`node.restart`, `preset.apply`, …). It is **fail-closed**: the wildcard
`admin` role is allowed everything; otherwise an action must be explicitly
mapped to a role. This is the designed seam for future RBAC / multi-tenant
rules.

Reaching the HTTP API with a grant is itself an authorized action, `api.access`.
Unmapped by default, it therefore requires `admin` — which is what keeps a node's
credential (`node-account`, holding only `node`) from operating the fleet through
the API it authenticates to. A deployment that wants a read-only operator role
maps `api.access` to it.

## Identity

`UidComputer` derives a stable, content-addressed `OmnyUid` from a node/hub's
key material plus machine attributes (TLV-framed, SHA-256, domain-separated per
kind) so identity can't be spoofed by merely claiming a different label.

## Auditing

Every security- and operationally-relevant action is recorded to an
`AuditRepository` via `AuditLog` (who, what, target, outcome, when) with a
stable id and timestamp. The HTTP API exposes recent entries at
`/api/v1/audit`.

## Reporting

Report vulnerabilities privately to the maintainers rather than via public
issues.
