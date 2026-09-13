# A fleet of servers, in Docker

One Hub and three nodes, each in its own container, on a private network — plus
the browser dashboard, so you can watch the fleet rather than only read about
it. The nodes dial the Hub over `wss://` and verify its certificate for real:
there is no `--insecure` anywhere here.

Run it from the **repository root**:

```sh
docker compose -f example/docker_fleet/compose.yaml up --build -d

open http://localhost:8080                        # the dashboard
dart run example/docker_fleet/fleet_tour.dart     # the same fleet, over the API

docker compose -f example/docker_fleet/compose.yaml down -v
```

The first build compiles the CLI and the dashboard, so it takes a few minutes.
After that, bringing the fleet up takes seconds. Sign-in details and the
one-time certificate step are [below](#the-fleet-in-a-browser).

## What is in it

| Container   | Image     | Labels                    | What it is                  |
| ----------- | --------- | ------------------------- | --------------------------- |
| `certs`     | runtime   | —                         | Issues the CA and the Hub's certificate, then exits |
| `hub`       | runtime   | —                         | The Hub: node channel, REST API and shell broker on one TLS port |
| `dashboard` | dashboard | —                         | The browser dashboard, on <http://localhost:8080> |
| `worker-1`  | runtime   | `env=prod`, `region=eu`   | A bare host — nothing installed |
| `worker-2`  | runtime   | `env=prod`, `region=us`   | A bare host — nothing installed |
| `builder-1` | sdk       | `env=staging`, `role=builder` | A host that happens to have the Dart SDK |

Every container runs the **same binary**. Which role it plays is the first
argument and nothing else, which is most of what there is to know about
deploying OmnyServer.

`builder-1` exists to make one point that a single-machine demo cannot: the two
workers and the builder are the same agent, and they advertise different
capabilities because their hosts differ. Nothing told them what they have; they
looked.

## The fleet in a browser

<http://localhost:8080> — the same fleet, in the dashboard.

**Accept the Hub's certificate first.** The fleet issues its own, and a browser
owns its own TLS stack: there is no in-page `--insecure` to offer, and a page
cannot ask you about a certificate for a *different* origin. So open

> <https://localhost:8443/healthz>

click through the warning once, and you should see `{"status":"ok"}`. That
exception is per-origin and sticks, and the certificate is reissued only when
you `down -v` — so this is a one-time step, not a per-run one.

Then sign in at <http://localhost:8080> with:

| Field        | Value                     |
| ------------ | ------------------------- |
| Hub address  | `https://localhost:8443`  |
| Principal    | `alice`                   |
| Token        | `admin-token`             |

`alice` is an **admin** grant (`--grant alice:admin-token:admin`), so the whole
dashboard is enabled. The Hub's master token (`api-secret`, no principal) works
too, and to see what a narrower credential looks like, issue one from the
Credentials screen and sign in with that instead — a `viewer` gets the fleet
read-only, with the control buttons gone rather than merely disabled.

What is worth looking at:

- **Fleet** — the three nodes, their labels, and the same filter the CLI's
  `--label` does.
- **A node** — its capabilities, and **live status**: CPU, memory, storage and
  the process table, busiest first. A browser `top`, of a container.
- **Run** — formulas come from the Hub's catalogue, so try `dart verify` on
  `builder-1` and then on `worker-1`: the same request, two answers, because
  the work happens on the node.
- **Declared state** — what you set with the tour, and whether it still holds.
- **Activity** — the events and the audit trail, filling in as you click.
- **Shell** — a real terminal on any node. The Hub runs a shell broker
  (`--shell`) and each node serves a session (`--with-shell`), and the grant you
  signed in with authenticates both, so it opens with no second login.

Two flags make this work at all, and both are in `compose.yaml`:
`--cors-origin=http://localhost:8080` on the Hub (a browser will not hand a page
a cross-origin response unless the server names the origin) and `--shell` for
the terminal. Without the first you get network errors and nothing else.

If you would rather not click through a warning, trust the CA at the OS level
instead:

```sh
docker compose -f example/docker_fleet/compose.yaml cp hub:/certs/ca.crt ./fleet-ca.crt
# macOS:
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ./fleet-ca.crt
```

## What the tour shows

`fleet_tour.dart` drives the running fleet through the REST API — the same API
a dashboard or a deploy script would call — and prints:

1. **The fleet.** Three nodes, their platforms and labels, and what each one
   found on its own host (`builder-1` reports `dart, git, ssh`; the workers
   report nothing, because there is nothing).
2. **Selecting by label.** `env=prod` is two machines, `role=builder` is one.
   You address the fleet by what a node *is*, not by where it is.
3. **Running a formula.** The same `dart verify` request to two hosts, with two
   different answers — which is the proof the Hub did not run it, the node did.
4. **Desired state.** `builder-1` is declared to be `dart` + `docker`; the drift
   report says it would skip `dart` (already present) and run `docker`. Nothing
   has run: this is a question about the node, not an instruction to it.
5. **Credentials.** A `viewer` grant is issued, reads the fleet, is refused when
   it tries to restart a node (`403 … this credential can read the fleet, not
   change it`), and is revoked.
6. **The audit trail.** Every one of the above, recorded with who did it.

## Things worth trying

```sh
# The fleet from the CLI instead, in a throwaway container:
docker compose -f example/docker_fleet/compose.yaml run --rm --no-deps hub \
  nodes list --api=https://hub:8443 --token=api-secret --ca=/certs/ca.crt

# Kill a node and watch the Hub notice (the `offline for 30s` alert):
docker compose -f example/docker_fleet/compose.yaml stop worker-1

# Restart the Hub: it is persisted to a volume, so the fleet, the audit trail
# and anything issued with `grant add` survive it.
docker compose -f example/docker_fleet/compose.yaml restart hub

# Follow what a node is doing:
docker compose -f example/docker_fleet/compose.yaml logs -f builder-1
```

`down -v` removes the volumes too, which is what makes the next `up` a clean
fleet rather than the same one.

## The same shape, asserted

`test/docker/` runs this arrangement as integration tests — a fleet forming,
TLS being refused without the CA, a Hub restarting with its state intact. Both
build from the same `docker/Dockerfile`.

```sh
dart test -t docker
```
