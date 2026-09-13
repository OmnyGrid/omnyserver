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
After that, bringing the fleet up takes seconds. Sign-in details are
[below](#the-fleet-in-a-browser) — there is no certificate to accept.

## What is in it

| Container   | Image     | Labels                    | What it is                  |
| ----------- | --------- | ------------------------- | --------------------------- |
| `hub`       | runtime   | —                         | The Hub: node channel, REST API and shell broker on one TLS port. Issues the fleet's certificate on the way up |
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

The Hub issues the fleet's certificate itself, on the way up, into a volume the
others mount read-only — so there is nothing to prepare, nothing of the fleet's
on your machine, and no one-shot container left behind afterwards. Everything
else waits on the Hub's healthcheck, because a node and the proxy both read the
CA at startup and neither can be told to wait for a file. It is issued once and
kept: `down -v` is what starts over.

## The fleet in a browser

<http://localhost:8080> — the same fleet, in the dashboard. Nothing to accept,
nothing to install, no certificate warning.

Sign in with:

| Field        | Value                     |
| ------------ | ------------------------- |
| Hub address  | `http://localhost:8080`   |
| Principal    | `alice`                   |
| Token        | `admin-token`             |

Yes — the Hub address is the dashboard's own address. The `dashboard` service is
nginx: it serves the compiled page *and* proxies what the page asks of the Hub
(`nginx.conf`). So the browser only ever talks to one origin, over plain HTTP on
localhost.

**That is deliberate, and it is the only arrangement that works.** The fleet
issues its own certificate, and nothing can make a `localhost` certificate
publicly valid. A browser owns its TLS stack — there is no in-page `--insecure`
— and, crucially, a page cannot be asked about a certificate for a *different*
origin: the request just fails with `The certificate for this server is
invalid`. Pre-accepting it in another tab is a Chrome-ism that Safari does not
honour. Moving the TLS to the proxy removes the question instead of answering
it.

The TLS itself does not go away. nginx speaks real `https` to the Hub and
verifies it against the fleet CA — `proxy_ssl_verify on`, checked against the
name the certificate was issued for. Point it at the wrong name and it refuses
with a 502 rather than connecting anyway. This is also how a Hub is fronted in
production, with the proxy holding a publicly-trusted certificate.

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

  The one to watch is **`procps install`**. The process table starts empty on
  every node here, because the agent reports it by shelling out to `ps` and
  these images ship without one — CPU and memory are fine, processes are
  missing. Install it from the Run screen and the table fills in on the next
  heartbeat, without anything restarting.

- **Declared state** — what you set with the tour, and whether it still holds.
- **Activity** — the events and the audit trail, filling in as you click.
- **Shell** — a real terminal on any node. The Hub runs a shell broker
  (`--shell`) and each node serves a session (`--with-shell`), and the grant you
  signed in with authenticates both, so it opens with no second login.

The terminal needs one Hub flag, `--shell`, and one node flag, `--with-shell`.
Both are in `compose.yaml`; without them the rest of the dashboard works and
"Open shell" does not.

### Pointing it straight at the Hub instead

If you would rather the page talked to `https://localhost:8443` itself — the
arrangement the proxy exists to avoid — two things have to be true, and the
second is the awkward one:

1. The Hub must name the dashboard's origin, which it does:
   `--cors-origin=http://localhost:8080` is already in `compose.yaml`. Without
   it a browser will not hand the page a cross-origin response at all.
2. Your machine must *trust* the fleet CA — accepting the warning in another
   tab is not enough for a cross-origin request:

```sh
docker compose -f example/docker_fleet/compose.yaml cp hub:/certs/ca.crt ./fleet-ca.crt
# macOS — and then restart the browser:
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ./fleet-ca.crt
```

That is a real change to your system trust store for a throwaway dev CA, which
is why it is not the default path here. Remove it afterwards with
`sudo security delete-certificate -c "OmnyServer Dev CA"`.

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
