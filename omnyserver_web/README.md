# OmnyServer Web

A browser dashboard for an [OmnyServer](https://github.com/OmnyGrid/omnyserver)
Hub: see the fleet, watch a node's live status, run formulas and presets, and
open a real shell on any node — with **no custom backend**. The page talks
directly to the Hub's REST API, using the same `HubApiClient` the CLI drives it
with.

Built as a plain Dart→JS app (`package:web` + `build_web_compilers`), not
Flutter. The state primitives, UI kit, router and the whole terminal stack are
imported from [`omnyshell_web`](https://github.com/OmnyGrid/omnyshell_web), so
the two apps read as one product and the hard parts are solved once.

## Features

- **Login with a grant.** A principal *and* its token
  (`hub start --grant alice:admin-token:admin`) — an identity the Hub verifies,
  whose roles decide what you may do. The Hub's master `--api-token` also works;
  leave the principal empty. Either way `whoami` runs at login, so a bad token
  fails *there* rather than on the first screen.
- **Fleet.** Every node, with online state, platform and labels, and a filter.
  The cached list paints instantly on reload while the fetch runs.
- **Node detail.** Platform, capabilities, labels — and **live status**: CPU
  (usage, cores, load average), memory, per-device storage, and the process
  table, busiest first. A browser `top`.
- **Control.** Restart, shut down, update the agent — each behind a confirmation,
  and hidden entirely if your roles do not permit it.
- **Activity.** The event feed, and the audit trail showing the principal the Hub
  *verified* rather than one a caller claimed.
- **Shell.** A real terminal on any node — see below.
- **Theme and PWA.** Light/dark/system with no flash, installable to a home
  screen.

## The shell

The Hub can serve both fleets from one port: `hub start --shell` mounts an
OmnyShell broker beside the REST API, and the *same grant* authenticates against
both. So "Open shell" reuses the credentials you already signed in with, and the
terminal itself — the xterm surface, the shell driver, the on-screen key bar, and
the sizing engine that keeps it usable against a soft keyboard — is imported
wholesale from `omnyshell_web`. None of it is reimplemented here.

It needs the Hub to host a broker (`hub start --shell`), the node to run one
(`node start --with-shell`), and your token to have been remembered — the shell
authenticates in band, so it needs the token itself, not merely a session.

## Running it

```sh
dart pub get
dart run omnyshell_web:copy_assets   # xterm bundle + kit.css + terminal.css → web/
dart pub global activate webdev
webdev serve                         # → http://localhost:8080
```

You need a Hub, and **two of its flags are not optional** for a browser client:

```sh
cd ..
dart run bin/omnyserver.dart cert gen --out certs
dart run bin/omnyserver.dart hub start \
  --cert certs/server.crt --key certs/server.key \
  --api-token api-secret \
  --grant alice:admin-token:admin \
  --grant node-account:node-token:node \
  --shell \
  --cors-origin http://localhost:8080     # ← the dashboard's origin

dart run bin/omnyserver.dart node start --hub wss://localhost:8443/node \
  --id worker-01 --principal node-account --token node-token \
  --ca certs/ca.crt --with-shell
```

- **`--cors-origin`** — a browser will not hand a page a cross-origin response
  unless the server says that origin may have it, and the dashboard is *always* a
  different origin than the Hub (here `:8080` against `:8443`). Without it you get
  network errors and nothing else.
- **A certificate the browser trusts.** The browser owns the TLS stack: there is
  no in-page `--insecure` to offer, and a self-signed Hub simply will not load.
  For local development, trust `certs/ca.crt` at the OS level, or front the Hub
  with a publicly-trusted certificate.

Then sign in at <http://localhost:8080> with the Hub address, `alice`, and
`admin-token`.

## Layout

```
core/    OmnyServerService — the only thing that touches the Hub. Owns the
         HubApiClient, normalizes the URL a human typed, turns every failure
         into an AppError worth showing.                      [VM-testable]
state/   Auth and fleet controllers, over Observable/AsyncState.
                                                              [VM-testable]
app/     bootstrap (wiring), AppContext, App (route guard + screen mounting)
ui/      screens: login, fleet, node detail, activity, shell
```

The service and state layers import `omnyshell_web/foundation.dart` — the DOM-free
barrel — so they run on the VM and are unit-testable with `dart test` rather than
needing headless Chrome. Only `app/` and `ui/` touch the page.

## Testing

```sh
dart analyze
dart test          # VM: the service, against a real Hub
webdev build       # the dart2js gate — see below
```

`test/service_against_real_hub_test.dart` starts a genuine `OmnyServerHub` with a
genuine `HttpApiServer` and drives the app's own `OmnyServerService` against it,
swapping only the transport (`IoApiTransport` for the browser's `fetch`) — which
is precisely the seam that exists for it. So it catches what a mocked test never
would: a field the Hub really names differently, a status code it really returns,
an entity that does not really decode.

**Always check the build produced a real bundle.** `dart2js` emits *no output at
all* for an entrypoint whose graph reaches an unsupported SDK library such as
`dart:io`: the build looks like it succeeded and the page is simply blank. A
healthy `build/web/main.dart.js` here is ~340 KB — a few hundred bytes means
something pulled `dart:io` back in. Upstream, `omnyserver`'s
`web_barrel_dart_io_free_test.dart` walks the import graph and fails if it does.
