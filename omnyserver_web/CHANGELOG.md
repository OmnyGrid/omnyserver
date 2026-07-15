## 0.2.3

- Rebuilt against **OmnyServer 0.15.1** — the login footer now reads
  `Dashboard v0.2.3 · OmnyServer v0.15.1`. The dependency floor moves to
  `^0.15.0` (the deploy path-overrides it to the server in this repo, so the
  dashboard ships beside the API it was built with).

## 0.2.2

- **The login screen now shows its versions** — the dashboard build and the
  OmnyServer version it was built against, e.g. `Dashboard v0.2.2 · OmnyServer
  v0.15.0`. Both are compile-time (you are not connected to a Hub yet), so the
  line names the API the dashboard targets, not the Hub you go on to sign in to
  — which the tooltip spells out. A `omnyServerWebVersion` constant
  (`lib/version.dart`), kept in sync with `pubspec.yaml` by a test, backs it.

- **Dropped `frame-ancestors` from the injected Content-Security-Policy.** It is
  only honoured in a real HTTP header, never in a `<meta>` tag — and GitHub Pages
  does not let us set headers — so it bought no clickjacking protection and cost
  a console error on every page load. Removing it clears the error; every other
  directive is unchanged. (The `.map` 404s in the console are release-build noise
  and unrelated.)

## 0.2.1

- **Icons — the dashboard can now be installed.** The manifest shipped with
  `"icons": []`, which is not a cosmetic gap: a PWA with no icon is one the
  browser will not offer to install, so "installable" was a claim the app could
  not honour.

  Drawn from the OmnyGrid mark — the prompt chevron, the grid, the cursor. The
  grid is the part that means something here (it is the fleet), and it is also
  what tells this icon apart from OmnyShell's on a home screen, which is the
  chevron alone. `any` at 192 and 512 on the app's own rounded tile; `maskable`
  at both sizes, full-bleed with the mark inside the safe zone, so a platform
  cropping to a circle or a squircle does not clip it; plus an apple-touch icon
  and a favicon.

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
