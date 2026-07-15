## 0.15.1

A node that cannot start should say why, not go dark.

```sh
omnyserver node start --hub wss://hub:8081 --id web-01 --principal p --token t
Connecting to wss://hub:8081/node …
hub rejected the connection (forbidden): principal p may not register node
  web-01 (the node.register action needs the "node" role)
```

### Fixed

- **`node start` was silent when a connection failed.** The runtime already
  reported everything worth knowing — a rejected registration and the Hub's
  reason (`principal … may not register node …`), a connection refused, a bad
  certificate — but its logger defaulted to a no-op that OmnyServer never
  replaced, so a node that authenticated and was then refused registration (a
  grant with the wrong role) retried forever without a word. It took a live
  packet trace to find a one-line misconfiguration.

  The node runtime now logs through the CLI. A failure and its cause are printed
  once (repeats within a short window are collapsed, so a node that keeps
  retrying a rejection it cannot fix says why once, not once per backoff), and a
  terminal auth failure exits with `error: <reason>` instead of an unhandled
  exception and a stack trace. `--verbose` shows the full lifecycle — every
  attempt, handshake and heartbeat.

- **A wedged capability probe could freeze registration.** Capability detection
  shells out to `docker`, `nvidia-smi`, `clinfo` and the like, and the scanner
  waits for every probe before a node can register — with no timeout on any of
  them. A single stuck command (a hung GPU driver, a wedged Docker daemon) would
  hang the whole node, silently. Each probe now has a deadline; a timed-out probe
  is killed and the capability treated as absent.

### Added

- **`node start --verbose` (`-v`)** — surface the connection lifecycle, not just
  failures.

### Changed

- The Hub logs a refused node registration on its own side too (`refused
  registration: … needs the "node" role`), so `journalctl` shows it, not only the
  audit trail.

- Requires `omnyhub ^1.7.0`, which delivers a registration rejection to the node
  as a typed error the moment it arrives. Before it, a refused node waited out
  the register timeout (10s) on every attempt; now it fails — and logs why — at
  once.

---

## 0.15.0

A Hub you have to babysit is not a Hub you can run. And a Hub that answers
anybody is not a Hub you can leave running.

```sh
omnyserver service install hub  --tls-dir /etc/letsencrypt/live/hub.example.com
omnyserver service install node --hub wss://hub:8443 --id worker-01 --token …
omnyserver service status hub
```

### Fixed

- **The HTTP API was unauthenticated when no `--api-token` was set.**
  `HttpApiServer.tokenAuthenticator()` returned `null` in that case, and a
  service registered with a null authenticator is not authenticated at all — so
  a Hub started with grants but no API token served the whole API to anyone who
  could reach the port: list the fleet, read the audit log, run formulas on
  every node, issue credentials.

  `--grant` looked like it secured the API and did not. Grants are only ever
  consulted from *inside* the authenticator that was not there, which is why
  `whoami` answered `{"principal":"anonymous","authenticated":false}` even when
  handed a valid grant token.

  A Hub is controlled with the `--api-token` or with a grant's
  `(principal, token)` pair, and with nothing else. It now enforces that
  whether or not an API token is configured. A Hub with neither authenticates
  **nobody** rather than everybody, and says so at startup. `/healthz` and
  `/metrics` stay open on purpose — a load balancer and a Prometheus scraper
  carry no bearer token, and locking them would make the Hub look dead to the
  things that check whether it is.

  Anyone relying on the old behaviour was relying on an open API. Pass
  `--api-token`, or authenticate with a grant (`--token` + `--principal`).

### Added

- **`omnyserver service install | reinstall | reconfigure | uninstall | start |
  stop | restart | status | info <hub|node>`** — install the Hub or a Node agent
  as a native OS service: a systemd unit, a launchd job, or a Windows scheduled
  task.

  `hub start` runs in the foreground and dies with your terminal, which is fine
  until it is the thing your fleet talks to. Rather than hand you a unit file to
  adapt, the CLI installs **itself**: `service install` takes the same flags as
  `hub start`, reconstructs the command line, and bakes this executable plus
  those flags into the service definition. What the service runs at boot is what
  you would have typed. Paths are absolutized on the way in, so the unit does not
  depend on the directory you installed from.

  `--dry-run` prints the generated definition without touching the system.
  `--system` installs machine-wide instead of for your user. `service info` shows
  the parameters *and* the actual command the OS runs it with — the two are
  usually the same, and the day they are not is the day you need to see both.

  `reconfigure` re-applies changed flags to a running service; `reinstall`
  refreshes the binary while keeping the config it was installed with, which is
  how a fleet picks up a new release.

  On Windows this goes through the Task Scheduler, not the Service Control
  Manager: a plain Dart console app cannot answer the SCM's start handshake, and
  the SCM kills it for not answering (error 1053).

- **`--ephemeral` on `hub start`** — the escape hatch for the change below.

- **`--cors-origin '*'`** — allow any origin. It used to be accepted and then
  silently match nothing, since it was compared as a literal origin string: a
  flag that looked configured and did nothing, which is the very failure the rest
  of this release sets out to remove.

  A wildcard is a real widening — any page may call the API — but not an open
  door: the Hub sends no `allow-credentials`, so a browser attaches nothing
  ambient and a caller still needs a token it was given. The Hub says so at
  startup, because that is not a thing to discover by reading the flags months
  later. It cannot be mixed with a named allow-list: asking for both is asking
  for everything.

### Changed

- **`omnyserver hub start` now persists by default**, to `<OMNYSERVER_HOME>/hub`
  (i.e. `~/.omnyserver/hub`). It used to keep everything in memory unless you
  passed `--data-dir`.

  A Hub with optional persistence is a Hub that silently forgets the fleet, the
  audit trail, and every credential `grant add` ever issued — on every restart —
  and says nothing about it. That was survivable when you were watching it in a
  terminal. Supervised by an init system, with `Restart=always`, it is a trap:
  the Hub comes back up empty and healthy. Forgetting should be something you
  ask for, so now you do: **`--ephemeral`**.

  An explicit `--data-dir` still means exactly what it meant. Only the default
  moved. `HubConfig(dataDir: null)` is untouched, so the Dart API still defaults
  to in-memory — this is a CLI default, not a library one.

- **A Hub started with no `--cors-origin` now says so.** It was already the case
  that no origins meant no CORS middleware at all, and therefore a `200` with no
  `Access-Control-Allow-Origin` — indistinguishable, from the browser's side,
  from a Hub that had rejected the origin. Correct, and invisible: it took a
  browser console to find. It is now a line in the startup output, next to the
  data directory.

- `run-hub.sh` grows an `OMNYSERVER_CORS_ORIGIN` passthrough. Every other setting
  had one; the one that a web dashboard cannot work without did not.

- The dashboard's injected CSP drops `frame-ancestors`. It is only honoured in a
  real HTTP header, never in a `<meta>` tag, so it bought no protection and cost
  a console error on every page load.

---

## 0.14.0

Work that takes longer than a caller should be made to wait.

```sh
omnyserver formula run docker w1 --action install --async   # returns at once
omnyserver ops list
omnyserver ops show <id> --wait
```

### Added

- **`async: true` on `/nodes/{id}/formula`, `/presets/apply` and
  `/nodes/{id}/reconcile`; `GET /operations`, `GET /operations/{id}`;
  `--async` on the three CLI commands; `omnyserver ops list | show [--wait]`.**

  These calls answer synchronously: the caller waits, and the Hub gives up after
  `requestTimeout`. That is right for a `verify` — and wrong for an `install`,
  which can take minutes. The caller gets a timeout, **the node carries on
  working**, and the operator is told a failure that did not happen.

  `async` hands back a handle instead of an answer (`202`), and the work is *the
  same work* — `runFormula`, `applyPreset`, `reconcile`, dispatched rather than
  awaited. Only who waits for it changes, which is exactly why **the synchronous
  contract is untouched**: it is still the right answer for the calls it was right
  for, and a `verify` should just answer.

  A failure lands **on the operation**, because an error thrown into a caller who
  left has nowhere to go. `OperationStarted` / `OperationFinished` ride the event
  bus, so a client learns on the stream it is already watching rather than polling
  for an answer it will either ask for too often or find out about too late.

- The dashboard dispatches formula runs and preset applies asynchronously, and
  grows an operations tray that updates from the event stream. A browser tab is
  the worst possible place to wait on an install.

---

## 0.13.0

Alerts — and the distinction the whole thing rests on: **a condition is not an
alert**.

```sh
omnyserver hub start … --alert 'disk>90' --alert 'cpu>95 for 5m' --alert 'offline for 2m'
omnyserver alerts     # what is wrong right now; exits non-zero if anything is
```

### Added

- **`hub start --alert`, `GET /alerts`, `omnyserver alerts`, and an alerts panel
  on the dashboard.** Rules are judged on the heartbeats the Hub already receives,
  so alerting costs nothing extra and can never be staler than the fleet view.

  A node at 95% CPU for one heartbeat is a build running; at 95% for five minutes
  it is a problem. So a breach is *observed* immediately and *raised* only once it
  has held for the rule's duration — and an alert is announced **once**, not on
  every heartbeat, and **resolved** when it clears. Each of those is the
  difference between alerting and noise, and an operator who has learned to ignore
  alerts has no alerting at all.

  There are **no default rules**. A tool that invents its own thresholds is a tool
  that pages you at 3am about a disk it decided was too full.

- `AlertRaised` and `AlertResolved` ride the existing event bus, so an alert
  reaches the dashboard, `events --follow` and anything else watching by the paths
  that already exist, rather than needing a delivery mechanism of its own.

- `offline` rules get a ticker, because an absence produces no events: nothing
  else would ever notice that a node has now been gone *long enough*.

---

## 0.12.0

A node's log, readable without logging into the node.

```sh
omnyserver node logs worker-01          # the tail the Hub keeps
omnyserver node logs worker-01 -f       # keep printing as it happens
```

### Added

- **`GET /nodes/{id}/logs`, `/logs/stream` (SSE), and `omnyserver node logs [-f]`.**
  Nodes have been able to push log batches since the first commit, and the Hub
  decoded each one and **threw it away** — the code said so: *"Accepted and
  dropped: OmnyServer has no log sink yet."* So a node's log stayed on the node,
  where the only way to read it is to log into the machine, which is the thing a
  fleet tool exists to avoid.

  What the Hub keeps is a bounded, in-memory **tail** — the last 500 lines per
  node (`HubConfig.logCapacityPerNode`). Deliberately not persisted: logs are the
  highest-volume thing a fleet produces, and a Hub that wrote every line of every
  node to disk would quietly become a log server nobody asked for, filling the
  disk the audit trail and metric history actually need. This is for looking at a
  machine that is misbehaving *now*. It is not the audit trail, and it is not a
  substitute for shipping logs somewhere that keeps them.

- **`node start --ship-logs`** (on by default), and `LogShipper`. The other half
  of the same gap: `NodeAgent.sendLogs` existed and *nothing ever called it*. The
  agent's own log now goes to its terminal and to the Hub. Batched rather than
  sent line by line, because a control-frame round trip costs more than the line
  it carries; and best-effort rather than queued, because an agent that queues
  forever is an agent that eventually eats the machine.

- The dashboard grows a live log pane, which follows the bottom unless you have
  scrolled up — being yanked back to the tail while reading something is how a log
  pane becomes useless.

---

## 0.11.0

A catalogue of what a node can be asked to do, and a library of what has been
saved to ask.

```sh
omnyserver formula list                        # what nodes can actually do
omnyserver preset save docker-host.json        # once, on the Hub
omnyserver preset apply docker-host --label env=prod   # by id, not by file
```

### Added

- **`GET /formulas` and `omnyserver formula list`.** A client had no way to
  *discover* what a node implements — it had to be told, out of band, what to
  type into a free-text box, which is a client that gets it wrong. The catalogue
  lists each formula and the actions it supports.

  The specs moved into the domain (`standard_formulas.dart`) and the `Formula`
  implementations now read them from there, so there is one definition rather
  than two: a catalogue served by the Hub cannot promise a formula the nodes have
  never heard of. The Hub does not — and should not — import the code that runs
  them to find out what they are.

- **A preset library: `GET/POST /presets`, `GET/DELETE /presets/{id}`, and
  `preset save | list | show | delete`.** `PresetRepository` existed, with all
  three of its implementations, wired to nothing. Every operator shipped their own
  copy of a preset file, and the copies quietly diverged.

  `preset apply` now takes a saved preset's **id** as well as a file, and
  `POST /presets/apply` accepts `presetId`. The saved form is the one worth using:
  a file is whatever copy *that* caller happens to have; an id is the one
  everybody agrees on.

- `--data-dir` persists saved presets and site-registered formulas too.

---

## 0.10.0

Credentials the Hub hands out — and takes back — without a restart. And a Hub
that remembers anything at all.

```sh
omnyserver hub start … --data-dir /var/lib/omnyserver
omnyserver grant add bob --role viewer --note 'read-only dashboard'
omnyserver grant list
omnyserver grant revoke <id>          # the next request with that token fails
```

### Added

- **`grant add | list | revoke`, and `GET/POST/DELETE /grants`.** Grants were
  `hub start` flags: adding an operator, or revoking a leaked token, meant
  restarting the Hub and dropping every node with it. That was tolerable when the
  only client was a CLI holding a token in a shell variable. It is not, now that a
  browser stores one.

  **The Hub keeps a hash, not a token.** The plaintext exists exactly once, in the
  response that created it, and the Hub cannot show it again — so its storage is
  not a list of passwords, and a stolen grant file authenticates nobody. A lost
  token is replaced, not recovered, which is why a grant has an id you revoke it
  by.

  Issuing and revoking are `admin`-only (`grant.manage` is deliberately unmapped),
  so an operator can run the fleet but cannot quietly mint itself an admin token.
  The flag-based grants still work: a `CompositeAuthenticator` checks the ones
  baked into the command line, then the ones issued at runtime.

- **`hub start --data-dir <dir>`.** The Hub had *no persistence at all* — every
  node, every audit entry, every metric sample and every declared state lived in
  memory and died with the process. The repositories and their JSON-directory and
  SQLite implementations existed; nothing wired them up. Now `--data-dir` does,
  and an issued credential survives the restart that would otherwise have made
  runtime grants pointless.

---

## 0.9.0

Desired state and drift — the thesis the package was named for, and the one part
of it that was never wired up.

```sh
omnyserver state set docker-host.json --label env=prod   # declare; runs nothing
omnyserver state diff --label env=prod                   # has it drifted?
omnyserver state reconcile --label env=prod              # make it true again
```

### Added

- **`DesiredState`, `CurrentState`, `StateReconciler` and
  `DefaultStateReconciler` have existed in the domain from the very first commit,
  connected to nothing.** They are now a feature.

  `PUT /nodes/{id}/desired-state` declares what a node is supposed to be.
  `GET /nodes/{id}/drift` answers whether it still is, by planning what would have
  to run to make the declaration true again — an empty plan means no drift.
  `POST /nodes/{id}/reconcile` runs exactly that plan.

  **Declaring is not applying, and the split is the whole point.** Applying a
  preset and watching it succeed tells you only that it succeeded; it cannot tell
  you anything a week later, after somebody logged into the box and changed
  something by hand. A declaration keeps answering.

  Reconciling is idempotent by construction: a converged node has an empty plan,
  so the second run does nothing. That is what makes it safe on a timer or in a
  pipeline — and `state diff` exits non-zero when anything has drifted, so it is
  usable as a check.

- **`omnyserver state set | show | diff | reconcile | clear`**, all taking the
  same fleet selectors as the rest of the CLI (`--label env=prod`, `--all`).

- **`DesiredStateRepository`**, with the three implementations the other
  repositories have (in-memory, JSON-directory, SQLite), so a declaration outlives
  the Hub that recorded it. `HubConfig.reconciler` is the seam for a richer
  planner (dependency ordering, version comparison) later.

- `HubApiClient.put` and `.delete`, which the API had no need of until now.

---

## 0.8.0

A fleet you can address, and a credential that can only watch it.

```sh
omnyserver node start --id web-01 --label env=prod --label role=web
omnyserver nodes list --label env=prod
omnyserver formula run docker --label env=prod --action verify   # every prod node
```

### Added

- **Labels, end to end.** `NodeDescriptor` has carried a `labels` map since the
  beginning and nothing could ever *set* one — `node start` had no flag — so
  nothing could select on one either. Now `node start --label env=prod`
  advertises them at registration, and `GET /nodes?label=env=prod&online=true`
  filters on them server-side. Filtering at the Hub rather than in the client is
  the difference between asking which machines are the production ones and
  downloading the whole fleet to find out.

- **Fleet selectors.** `formula run` and `preset apply` took exactly one node.
  They now take `--label env=prod`, repeated `--node`, or `--all`, and report a
  result per node with a tally. The fan-out is sequential on purpose: these are
  fleet-changing operations, and a failure halfway through a hundred machines is
  far easier to reason about when the ones before it are known to have finished.

  A selector that matches nothing is an **error**, not a silent success —
  "applied to 0 nodes" reads like it worked, and is exactly how a typo in a label
  goes unnoticed until somebody wonders why production never changed.

- **A `viewer` role.** `api.access` was fail-closed on `admin`, so every
  dashboard user was a full operator and there was no way to hand somebody a link
  that could not also shut a machine down. `viewer` can reach the API and read
  everything — fleet, live status, history, events, audit — and change nothing;
  `operator` can also act.

  That required separating two questions the API had been conflating.
  Authenticating (`api.access`) is not the same as being *allowed to act*, so the
  mutating routes now consult the Hub's `Authorizer` per action
  (`node.restart`, `formula.run`, …). Without that second check the role would
  have been decoration: a viewer could still have restarted a machine.

  Existing deployments are unaffected — `admin` remains the wildcard, the master
  API token still acts, and a `node` credential still cannot reach the API at all.

---

## 0.7.0

History, a live stream, and the CLI commands the API always had but the CLI
never exposed.

```sh
omnyserver node metrics worker-01 --since 1h   # the samples the Hub already had
omnyserver events --follow                     # tail -f for the fleet
```

### Added

- **`GET /nodes/{id}/metrics`** and **`omnyserver node metrics <id>`**. The Hub
  has been recording a full `NodeStatus` to its `MetricRepository` on *every
  heartbeat* since the beginning — and nothing has ever read one back. This is
  that history, projected down to the handful of numbers a chart is actually
  drawn from (`MetricPoint`): a stored sample carries the whole process table, so
  serving it raw would cost megabytes to draw a line.

  `?since=` takes `30s` / `15m` / `1h` / `7d` as well as an ISO-8601 instant,
  because "the last hour" is the thing an operator means, and making them compute
  a timestamp for it is a small cruelty. `MetricRepository.recentFor` grew a
  `since` parameter, applied before `limit` so a window is a window and not
  "the newest N that happen to fall in one".

- **`GET /events/stream`** (Server-Sent Events) and **`omnyserver events -f`**.
  `/events` returns a bounded snapshot, so anything built on it is a few seconds
  stale and keeps re-fetching a list it has mostly seen. This is the same events,
  pushed — each flushed as it happens, with the event's type as the SSE `event:`
  name so a browser can `addEventListener('node.connected', …)` rather than
  switching on a payload field. `HttpApiServer.eventKeepAlive` tunes the ping.

- **The CLI commands the API already answered**: `node shutdown`, `node update`,
  `node show`, `node capabilities`, `events`, `audit`, `hub metrics`. The
  dashboard could do all of these and the CLI could not.

### Fixed

- **`HubApiClient` mangled query strings.** `Uri.replace(path: …)` percent-encodes
  a `?`, so `/nodes/x/metrics?since=1h` became a path with a `%3F` in it and
  matched no route at all — a 404 for *every* endpoint taking a parameter. Found
  by running the CLI against a real Hub; a unit test would not have noticed,
  because both sides were mocked.

- **Stopping the Hub blocked on live event streams.** An SSE response never ends,
  so a shutdown waited for each idle client's next keep-alive ping to fail — a
  Hub taking fifteen seconds to stop because somebody left a dashboard open.
  `HttpApiServer.close()` now hangs them up first.

---

## 0.6.0

The Hub becomes callable from a browser. This is the foundation for the
OmnyServer Web dashboard: the same `HubApiClient` the CLI drives the Hub with now
compiles to JavaScript and runs on a page.

```sh
omnyserver hub start --cert certs/server.crt --key certs/server.key \
                     --api-token api-secret --grant alice:admin-token:admin \
                     --cors-origin https://dashboard.example.com
omnyserver whoami --api https://hub:8443 --principal alice --token admin-token
```

### Added

- **`lib/omnyserver_client_web.dart`** — a browser-safe barrel: the REST client
  plus the entities it decodes (`NodeDescriptor`, `NodeStatus`, `OmnyEvent`,
  `AuditEntry`, …). A web app imports this and gets the *same* `fromJson` the Hub
  encodes with, so there is no second, drifting copy of the wire format.

  `test/unit/web_barrel_dart_io_free_test.dart` walks the barrel's import graph
  and fails if `dart:io` reappears anywhere in it. That is not fussiness:
  `dart2js` emits **no output at all** for an entrypoint that reaches an
  unsupported SDK library, so the build appears to succeed and the page is simply
  blank.

- **An HTTP transport seam.** `HubApiClient` now takes an `ApiTransport`:
  `IoApiTransport` (`dart:io`'s `HttpClient`) on the VM, `FetchApiTransport`
  (`fetch`) in a browser, or a fake in a test. TLS options moved onto the VM
  transport, where they belong — a browser owns its own TLS stack and cannot be
  handed a `SecurityContext` or told to accept a bad certificate.

- **`hub start --cors-origin <origin>`** (repeatable) and `HubConfig.corsOrigins`.
  A web dashboard is *always* a different origin from the Hub — in production and
  in development alike (`webdev` on `:8080`, Hub on `:8443`) — so without this the
  browser blocks every response and the app sees only network errors. Empty by
  default: a Hub with no browser client is unchanged, and no origin is trusted by
  accident.

  It is installed with `OmnyServerHub.useOuter` (new), *outside* the error mapper
  and authentication. Both matter. A `401`, `404` or `500` is rendered above
  ordinary middleware, so CORS mounted there could never stamp one — and a
  response a browser is not allowed to read arrives as an opaque network error,
  not as "your token is wrong". And a preflight carries no credentials by
  specification, so an authenticator that saw it first would reject it and no call
  would ever succeed.

- **`GET /api/v1/whoami`** and **`omnyserver whoami`** → `{principal, roles,
  authenticated}`. A client cannot answer either question for itself: it cannot
  tell a valid token from an invalid one until the first real call fails, long
  after the login form is gone, and it cannot know which roles it holds, so it
  would have to offer every action and let the Hub refuse half of them.

### Fixed

- `POST /nodes/{id}/formula` was missing from the OpenAPI document, so a client
  generated from it would silently lack the ability to run formulas.

---

## 0.5.0

Operators get an identity. The CLI's API commands now take `--principal`
alongside `--token`, presenting a Hub **grant** — the credential nodes already
use — instead of the Hub-wide master API token.

```sh
# hub start … --grant alice:admin-token:admin
omnyserver node status worker-01 --api https://hub:8443 \
                                 --principal alice --token admin-token
```

### Added

- `--principal` on every CLI command that calls the Hub API (`node status`,
  `node restart`, `nodes list`, `formula run`, `preset apply`). Paired with
  `--token`, it is verified against the same grant store the node control channel
  authenticates against: the principal and its roles come from the grant, not
  from the caller. `HubApiClient` sends the pair as `x-omny-principal` plus the
  bearer token.
- `api.access`, the action a grant must be authorized for to use the HTTP API.
  `RoleBasedAuthorizer` leaves it unmapped and so fail-closed on `admin`, which
  is what stops a node's own grant (role `node`) from operating the fleet through
  the API it can authenticate to — it gets a `403`.

### Changed

- The API's audit trail records the principal the Hub **verified** rather than
  the one the caller asserted in `x-omny-principal`. With the master API token
  the header still stands in as attribution (that token is already `admin`, so
  there is nothing to escalate); with a grant it is ignored in favour of the
  authenticated identity.
- The master API token is compared in constant time, as grant tokens already
  were.

Existing setups are unaffected: `--token api-secret` alone behaves exactly as
before, and an API with no `--api-token` stays open.

## 0.4.0

Certificates that renew themselves. The Hub can now take its TLS material from a
LetsEncrypt-style directory and reload it when it is renewed — matching
`omnyshell hub start --tls-dir`.

```sh
omnyserver hub start --tls-dir /etc/letsencrypt/live/hub.example.com \
                     --api-token api-secret --grant node-account:node-token:node
```

### Added

- `hub start --tls-dir <dir>`: reads `fullchain.pem` + `privkey.pem` from the
  directory instead of `--cert`/`--key`. The files are re-checked periodically
  and, when a renewal changes them, the Hub rebinds its listener with the fresh
  certificate — no restart, with established connections draining on the old
  listener. Passing `--tls-dir` together with `--cert`/`--key` is an error, and
  the Hub still refuses to start without one of the two (no insecure mode).
- `HubConfig.tlsDirectory` and `HubConfig.tlsReloadInterval`, the embedded
  equivalent. Exactly one of `securityContext` or `tlsDirectory` must be given.

### Changed

- `HubConfig.securityContext` is now nullable and no longer `required` (a
  `tlsDirectory` may take its place). Existing code that passes a
  `securityContext` is unaffected.

## 0.3.1

Dependency maintenance — no API or behaviour changes.

### Changed

- Widened the dependency floors to the current releases: `omnyhub` 1.5.1,
  `omnyshell` 1.56.1, `sqlite3` 2.9.4, `meta` 1.19.0 and `path` 1.9.1.

## 0.3.0

One Hub, two kinds of node. An OmnyServer Hub can now also serve
[OmnyShell](https://pub.dev/packages/omnyshell) nodes — same port, same
certificate, same credentials — and one node process can be both an OmnyServer
agent and an OmnyShell node.

```sh
# Hub: three surfaces on one TLS port
omnyserver hub start --cert … --key … --shell
#   /node    → OmnyServer node control channel
#   /shell   → OmnyShell broker
#   /api/v1  → REST API

# Node: one process, both roles, one service unit
omnyserver node start --hub wss://hub:8443 --id worker-01 --token … --with-shell

# …or attach a standalone OmnyShell node to the same Hub:
omnyshell node start --hub wss://hub:8443/shell --id worker-01 --token …
omnyshell exec worker-01 'uptime' --hub wss://hub:8443/shell …
```

### Added

- **`--shell` / `--shell-path` on `hub start`** mount an OmnyShell broker on the
  Hub's listener (`ShellHub`, exported from `omnyserver_hub.dart`). It shares the
  Hub's `--grant` token table, so one credential set serves both fleets and there
  is nothing extra to provision. Authorization stays OmnyShell's: `admin` may open
  a session on any node, other roles only on nodes whose `allow-roles` label names
  them.
- **`--with-shell` / `--shell-path` / `--shell-label` on `node start`** also run an
  OmnyShell node in the same process — one binary, one service unit, one
  supervision target. It uses the same PTY backend `omnyshell node start` does.
- `HubConfig.shellMount` (default `/shell`), and a `connectionAuthenticator`
  parameter on `OmnyServerHub.registerService()`.

### Fixed

- **OmnyServer's node handshake was imposed on every WebSocket mount.** It was
  registered hub-wide, and omnyhub resolves a route's connection authenticator as
  `route.connectionAuthenticator ?? hubWide` — a route's `null` means *inherit*,
  not *none*. Any co-hosted WebSocket service would therefore have had OmnyServer's
  handshake run against it: a peer speaking its own protocol would have had its
  frames eaten by a handshake meant for someone else and been rejected after a
  10-second timeout. The handshake is now attached to the node channel's route
  alone. (Latent before this release, since nothing else was mounted; it is what
  made co-hosting possible.)

### Changed

- Depends on `omnyshell ^1.56.0`.
- `run-hub.sh` now forwards extra flags to the CLI, so `./run-hub.sh --shell`
  works. It silently dropped them before.

## 0.2.1

### Fixed

- **A node's status was unavailable for a full heartbeat interval after it
  registered.** Heartbeats are periodic, so the snapshot they carry is one
  interval away; on the default 15-second cadence the Hub reported *no status at
  all* for a node that had just come up (`GET /api/v1/nodes/{id}/status` answered
  `404` for ~18 seconds). The agent now pushes a snapshot on becoming ready — on
  every (re)registration — so status is live immediately.

  Introduced in 0.2.0: the pre-omnyhub agent sent an eager first heartbeat for
  exactly this reason, and omnyhub's `NodeRuntime` beats only on its timer. The
  test suite could not see it, because the harness uses a 200 ms cadence and a
  beat always landed before the assertion.

### Changed

- `run-hub.sh` still passed `--api-port`, removed in 0.2.0 when the REST API moved
  onto the Hub's TLS port. It now uses `--node-path`.
- README: refreshed for the single-port model (the quick-start could not run as
  written), full badge set, and an OmnyGrid ecosystem section.

## 0.2.0

Hosts OmnyServer on [omnyhub](https://pub.dev/packages/omnyhub) — the HUB
framework OmnyGrid already builds on. OmnyServer had grown its own copy of most
of it: a WebSocket transport, a node registry, a heartbeat watchdog, an RPC
correlation map, a reconnect policy and a hand-rolled HTTP router, several with
the same class names as omnyhub's. All of that is now omnyhub's, and roughly
1,500 lines of duplicated infrastructure are gone.

What stayed is what is actually OmnyServer's: identity, capability detection,
formulas, presets, desired-state reconciliation, auditing, events, metrics and
persistence.

### Breaking

- **The Hub and its REST API now share one TLS port.** Nodes upgrade to a
  WebSocket on `HubConfig.nodeMount` (default `/node`); operators call
  `/api/v1`, `/healthz` and `/metrics` on the same host and port, over the same
  certificate. The API is no longer a second, plaintext listener.
  - CLI: `--api-host` and `--api-port` are gone; `--node-path` is new.
  - `NodeAgentConfig` takes the Hub URL (`wss://hub:8443`) and fills in the
    mount itself via `nodeMount`. A URL that already carries a path is honoured
    as-is, for a node behind a path-rewriting proxy.
- **The hub↔node wire protocol is omnyhub's.** Registration, heartbeats,
  discovery and RPC are `register`/`heartbeat`/`query`/`request`/`notify`.
  OmnyServer's operations (`op.formula.run`, `op.node.control`, …) ride as the
  `action` + `payload` of an omnyhub `NodeRequest`/`NodeNotify`, so the operation
  vocabulary and every handler signature (`FormulaHandler`, `ServiceHandler`, …)
  are unchanged. A 0.1.0 node cannot talk to a 0.2.0 Hub.
- **The Hub advertises the heartbeat cadence and nodes honour it.** A fleet's
  liveness budget belongs to the Hub, so set `HubConfig.heartbeatInterval`;
  `NodeAgentConfig.heartbeatInterval` is now only a fallback for a Hub that
  advertises none.
- **`OmnyServerHub.registry` is omnyhub's `NodeRegistry`**, and `runFormula` /
  `applyPreset` return `FormulaRunResult` / `PresetApplyResult` instead of an
  untyped `ControlMessage`.
- Removed: `OmnyConnection`, `OmnyFrame`, `FrameCodec`, `WebSocketConnection`,
  `WsServerEndpoint` and OmnyServer's own `NodeRegistry` — omnyhub provides all
  of them. Also removed the parts of the protocol that had no production callers:
  the binary `DataFrame`/`DataOpcode` channel, `Ping`/`Pong`, `FormulaProgress`
  and `ControlMessage.channelId`.
- The REST wire contract is **unchanged** — same routes, status codes, bearer
  auth and `{"error":{"code","message"}}` envelope — so HTTP consumers and the
  CLI's API client are unaffected. Its contract test passes unmodified.

### Fixed

- **Node registration is now authorized, not merely authenticated.** `HubConfig`
  accepted an `Authorizer` and never called it, so any principal that could
  authenticate could register under — and thereby hijack — *any* node id. The
  Hub now authorizes `node.register` with the claimed id as the target, and
  `RoleBasedAuthorizer` grants it to the `node` role by default. A node
  credential can enrol a node and nothing else.
- **A node that failed authentication reconnected forever.** A revoked key is not
  fixed by retrying; the agent now treats an auth failure as terminal and stops.
- **A stale node's socket was leaked.** The heartbeat watchdog marked a node
  offline without closing its connection or cancelling its subscription, so a
  later close fired the disconnect path a second time and published a duplicate
  `NodeDisconnected`.
- **Node liveness could be lost to a slow metrics collector.** Status now rides
  the heartbeat as a payload; a status provider that throws or stalls leaves the
  beat itself untouched.

### Added

- `HubConfig.nodeMount`, `heartbeatInterval` and `requestTimeout` — the last of
  which was a hardcoded 30-second literal with no way to change it.
- `HttpApiServer.buildServices()` / `buildMiddleware()` — mount the REST API on
  any hub (that is how it shares the Hub's port), or keep `start()` to run it
  standalone.
- `NodeAgent.sendLogs()` and `reportStatus()` — one-way pushes to the Hub, on
  omnyhub's `notify`.

## 0.1.0

- Initial release of OmnyServer — a distributed server-orchestration platform.
- Hub runtime over WebSocket-on-TLS: node registration, authentication,
  heartbeat monitoring, live registry, audit log and event aggregation.
- Node agent: connect/auth/register/heartbeat with automatic reconnection;
  command, formula, preset, service and node-control handlers.
- Live monitoring (CPU, memory, storage, OS, processes) and dynamic capability
  detection (Docker, Podman, Dart, Python, Java, Node.js, Git, SSH, CUDA, Metal,
  OpenCL).
- Formula engine with idempotent built-in Docker and Dart formulas, presets, and
  capability-aware desired-state reconciliation.
- Pluggable persistence: in-memory, JSON-directory and SQLite repositories with
  a shared conformance suite.
- Token and Ed25519 public-key authentication, role-based authorization,
  content-derived identity (UID) and dev TLS certificate generation.
- Versioned REST HTTP API (`/api/v1`) with OpenAPI, auth/validation, structured
  errors, recent events/audit, and a Prometheus `/metrics` endpoint.
- `omnyserver` CLI (hub, node, nodes, preset, formula, cert) — every command
  backed by the same public APIs.
- Service management via `dart_service_manager` (systemd / launchd / Windows).
