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

## Authorization

`RoleBasedAuthorizer` decides whether a `Principal` may perform an action
(`node.restart`, `preset.apply`, …). It is **fail-closed**: the wildcard
`admin` role is allowed everything; otherwise an action must be explicitly
mapped to a role. This is the designed seam for future RBAC / multi-tenant
rules.

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
