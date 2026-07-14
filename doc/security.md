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

`/api/v1` is always authenticated. Two credentials are accepted, and there is no
third — and no way in without one of them:

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

`--api-token` is therefore optional, but **omitting it does not open the API** —
it only removes the master key, leaving grants as the way in. A Hub started with
neither authenticates nobody: every call is a `401`, and the Hub says so at
startup rather than looking healthy while answering no one.

> Until 0.15.0 this was not true. With no `--api-token`, the API was registered
> with *no authenticator at all* and served every route to anyone who could
> reach the port — grants are only consulted from inside that authenticator, so
> `--grant` looked like it secured the API and did not. If you run a Hub without
> `--api-token`, upgrade.

`/healthz` and `/metrics` sit outside the API service and stay open: a load
balancer and a Prometheus scraper carry no bearer token, and gating them would
make the Hub look dead to the things that check whether it is alive. Neither
exposes fleet data.

## Authorization

`RoleBasedAuthorizer` decides whether a `Principal` may perform an action
(`node.restart`, `preset.apply`, …). It is **fail-closed**: the wildcard
`admin` role is allowed everything; otherwise an action must be explicitly
mapped to a role. This is the designed seam for future RBAC / multi-tenant
rules.

Reaching the HTTP API with a grant is itself an authorized action, `api.access` —
which is what keeps a node's credential (holding only `node`) from operating the
fleet through the API it authenticates to. It is refused at the door.

The default policy defines three operator roles, and the distinction between the
first two is the point:

| Role | `api.access` | Mutations (`node.restart`, `formula.run`, …) |
|---|---|---|
| `viewer` | yes | no |
| `operator` | yes | yes |
| `admin` | yes (wildcard) | yes (wildcard) |
| `node` | **no** | no — only `node.register` |

**Authenticating is not the same as being allowed to act.** A `viewer` holds
`api.access`, so the API cannot treat "you got in" as "you may do this": every
mutating route consults the `Authorizer` for its own action. Without that second
check the role would be decoration, and a read-only credential could still shut a
machine down.

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
