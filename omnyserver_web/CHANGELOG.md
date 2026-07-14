## 0.2.0

The dashboard: a browser you can run a fleet from.

A static, installable PWA that operates an OmnyServer Hub with no backend of its
own — it is the Hub's REST API, seen. Deployed to
[GitHub Pages](https://omnygrid.github.io/omnyserver/), and equally servable
from the Hub itself.

### The fleet

- **Login** against a Hub URL with a grant (`principal` + `token`), validated up
  front by `whoami` — so a bad token fails at the door rather than on the first
  thing you try to do — and the roles it returns decide what the UI offers.
  Persisting the credential is opt-in.
- **Fleet overview** — every node, online and off, with platform, CPU, memory and
  disk; searchable, sortable, filterable by label. Painted instantly from cache,
  then reconciled against the Hub.
- **Node detail** — descriptor, platform, capabilities, labels; live status with
  CPU load, memory, per-device storage and a process table (a `top` in the
  browser).
- **Live event stream** over SSE, so the activity feed is a console rather than a
  poll, and the audit trail — now naming the *verified* principal behind each
  action.
- **Metrics history**, charted from the samples the Hub has been persisting on
  every heartbeat since long before anything read them back.

### Control

- Restart, shutdown and update a node; run a formula; apply a preset — behind
  confirmation, and behind the role that permits it.
- **Fleet selectors**: act on one node, on a label (`env=prod`), or on all of
  them, with a per-node result matrix rather than a single verdict.
- **Desired state and drift** — declare what a node should be, see how it differs
  from what it is, and reconcile.
- **Long operations run asynchronously**: an install that outlives a request no
  longer times out in the browser. The running-ops tray tracks it to completion.
- **Grants**, managed live — an operator can now be added or revoked without
  restarting the Hub.
- **Alerts** — a threshold held long enough to mean something (disk over 90%, a
  node offline past its grace), raised once and resolved once.

### The shell

- **Open a shell on any node**, in the dashboard. The terminal — xterm view, PTY
  bridge, mobile fit engine, accessory bar — is imported from
  [`omnyshell_web`](https://pub.dev/packages/omnyshell_web) rather than rebuilt,
  and drives the OmnyShell broker the Hub hosts on the same port. One Hub, one
  certificate, one login.

### Notes

- Storage is namespaced `omnyserver.`, so the dashboard and an OmnyShell app
  served from the same origin do not overwrite each other's theme, hub and token.
- Light, dark and system themes; the service worker precaches the app shell but
  never the Hub — live fleet state must not be answered out of a cache.
- Not published to pub.dev: this is an application, versioned alongside the API
  it speaks to.

## 0.1.0

- Initial project scaffold.
