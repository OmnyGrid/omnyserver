# A fleet of servers, in Docker

One Hub and three nodes, each in its own container, on a private network. The
nodes dial the Hub over `wss://` and verify its certificate for real — there is
no `--insecure` anywhere here.

Run it from the **repository root**:

```sh
docker compose -f example/docker_fleet/compose.yaml up --build -d
dart run example/docker_fleet/fleet_tour.dart
docker compose -f example/docker_fleet/compose.yaml down -v
```

The first build compiles the CLI, so it takes a couple of minutes. After that,
bringing the fleet up takes seconds.

## What is in it

| Container   | Image   | Labels                    | What it is                  |
| ----------- | ------- | ------------------------- | --------------------------- |
| `certs`     | runtime | —                         | Issues the CA and the Hub's certificate, then exits |
| `hub`       | runtime | —                         | The Hub: node channel and REST API on one TLS port  |
| `worker-1`  | runtime | `env=prod`, `region=eu`   | A bare host — nothing installed |
| `worker-2`  | runtime | `env=prod`, `region=us`   | A bare host — nothing installed |
| `builder-1` | sdk     | `env=staging`, `role=builder` | A host that happens to have the Dart SDK |

Every container runs the **same binary**. Which role it plays is the first
argument and nothing else, which is most of what there is to know about
deploying OmnyServer.

`builder-1` exists to make one point that a single-machine demo cannot: the two
workers and the builder are the same agent, and they advertise different
capabilities because their hosts differ. Nothing told them what they have; they
looked.

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
