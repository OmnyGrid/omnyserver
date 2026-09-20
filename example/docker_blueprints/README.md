# A fleet with roles, declared by blueprints

Three empty containers become two web servers and a build host, because a
document said they should be.

```sh
docker compose -f example/docker_blueprints/compose.yaml up --build -d
dart run example/docker_blueprints/blueprint_tour.dart
docker compose -f example/docker_blueprints/compose.yaml down -v
```

Run it from the repository root. The image is built from your checkout, so this
is the code in front of you and not a published release.

Open <http://localhost:8080> while the tour runs — sign in with
`https://localhost:8443`, `alice`, `admin-token`. Each node's **Declared state**
card shows the same plan the tour prints, and the **Log** button on a running
apply follows the output of whichever package is being installed.

---

## What is in here

```
presets/base-tools.json        procps, net-tools — what every host gets
blueprints/web-server.yaml     base-tools + dns-utils + nmap
blueprints/build-host.yaml     base-tools + build-tools + dart
compose.yaml                   a Hub, a dashboard, three empty machines
blueprint_tour.dart            the walk-through
```

The containers arrive with **nothing installed**. That is the point: a machine
that already has everything on it demonstrates nothing about a tool whose job is
to put it there.

## The shape of it

A **blueprint** is what a machine *is*. A **preset** is a piece it is made of.
Only a blueprint is assignable to a node, which is what earns the two names.

```yaml
blueprint: web-server
name: Web server
includes:
  - base-tools           # shared with the build host — not copied
resources:
  - { type: formula, name: dns-utils, ensure: installed }
  - { type: formula, name: nmap, ensure: installed }
```

Every resource says what it should **be**, not what to do to it. That single
choice is why applying twice does nothing the second time, why drift detection
is the same comparison with the apply left off, and why removing software is
`ensure: absent` rather than a separate command.

`blueprint resolved build-host` shows what a node is actually sent: the includes
flattened in place, in the order they will be settled, each resource naming the
document that asked for it.

## What the tour demonstrates, in order

1. **Three machines**, labelled `role=web` and `role=build` and nothing else.
2. **The library** — one preset, two blueprints, and `build-host` resolved so
   you can see which line came from where.
3. **Assigning by role**, not by hostname. Nothing runs; a blueprint is a claim.
4. **The plan**, which the *node* produces. The Hub resolves the document and
   sends it; the node reads its own machine and answers. A plan built from what
   the Hub last heard would be a plan built from intentions.
5. **Applying.** Real `apt-get`, on real containers. Give it a minute the first
   time — `build-tools` is a compiler.
6. **Converged, and idempotent.** Applying again changes zero things.
7. **Removing two resources, and only removing one of them.** Both blueprints
   drop something they were declaring, and the node does something different
   with each:

   ```
   web-1     remove  formula:nmap    no longer declared by this blueprint
   build-1   left    formula:dart    ... it was already here before this blueprint

   web-1     nmap: absent
   build-1   dart: installed
   ```

   `nmap` was put there by the blueprint, so it goes. The Dart SDK was on
   `build-1` before any blueprint touched it, so it is **released** — dropped
   from the ledger and left exactly where it is. This system never owned it.

8. **Editing the shared preset.** `base-tools` gains `nmap`, and *neither
   blueprint is touched and neither node is contacted*. Both machines drift on
   their next plan, because an include follows the preset.
9. **The audit trail** of everything that just happened.

## Two things worth looking for

**Adoption.** `build-1` is built from the Dart image, so it already has a Dart
SDK before any blueprint touches it. `build-host.yaml` declares
`formula:dart ensure: installed`, which is already true — so the first plan
reports nothing to do, and the node records that resource as **adopted**. Step 7
is what that record buys: the blueprint stops asking for Dart, and the SDK
stays. Inferring ownership from the document instead would have uninstalled a
toolchain nobody here installed.

The flag only ever protects; `--purge-adopted` is how you say you meant it.

**Provenance.** Every line of a plan names its origin — `preset:base-tools` or
`local`. When a blueprint is composed from several pieces, "which document asked
for this?" is the first question, and it should not require reading four files
to answer.

## The ledger lives on a volume

Each node's record of what its blueprint put there lives under
`/root/.omnyserver`, mounted from a named volume. A node that forgets what it
owns adopts everything it finds and will never remove anything — the safe
failure, but it means a blueprint could not really be unassigned. `down -v`
removes those volumes along with everything else, which is how you start over.

## Two rough edges, named rather than hidden

- **Presets are JSON; blueprints can be YAML.** A blueprint's format is fixed
  when you author it and never converted, so `blueprint show` hands back the
  YAML you wrote with its comments intact. `preset save` has not caught up and
  still takes JSON only.
- **`reconcile` applies to one node at a time here.** The CLI's
  `blueprint apply --label role=web` fans out; this tour uses the REST API
  directly, one call per node, because it prints what each one did.

## See also

- [`../docker_fleet/`](../docker_fleet/) — the same fleet without blueprints:
  labels, formulas, shells, desired state, and a variant that runs every role as
  a systemd service the way a real server does.
- [`doc/architecture.md`](../../doc/architecture.md) — the Blueprints section,
  for where each piece lives and why planning happens on the node.
