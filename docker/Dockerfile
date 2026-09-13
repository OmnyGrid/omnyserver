# The image OmnyServer runs from in a container.
#
# Used by two things, which is why it lives here rather than beside either:
# `example/docker_fleet/compose.yaml` (a fleet you can bring up and poke at)
# and `test/docker/fleet.dart` (the same shape, asserted).
#
# One binary serves every role — Hub, node and CLI are the same executable — so
# a fleet is several containers of one image with different arguments.
#
# Two runtime targets, because "what a node can see on its host" is itself
# something worth testing:
#
#   runtime — Debian slim, nothing installed but openssl. A node here detects
#             no capabilities, which is the honest answer for a bare host.
#   sdk     — the Dart image, so `dart` is on the PATH. A node here advertises
#             the dart capability without anything being installed for it.

# ---------------------------------------------------------------------------
FROM dart:stable AS build

WORKDIR /src

# Resolved before the sources are copied, so editing Dart code does not redo
# dependency resolution on every rebuild.
COPY pubspec.yaml ./
RUN dart pub get

COPY . .
RUN dart pub get --offline
RUN dart compile exe bin/omnyserver.dart -o /src/omnyserver

# ---------------------------------------------------------------------------
# `debian:stable-slim` tracks the same Debian release the Dart image is built
# on, which is what an AOT binary needs: it is self-contained apart from glibc.
FROM debian:stable-slim AS runtime

# `cert gen` shells out to openssl, so a fleet can issue its own dev
# certificates without anything on the host being involved.
RUN apt-get update \
  && apt-get install -y --no-install-recommends openssl ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/omnyserver /usr/local/bin/omnyserver
ENTRYPOINT ["/usr/local/bin/omnyserver"]

# ---------------------------------------------------------------------------
FROM dart:stable AS sdk

COPY --from=build /src/omnyserver /usr/local/bin/omnyserver
ENTRYPOINT ["/usr/local/bin/omnyserver"]

# ---------------------------------------------------------------------------
# A host that runs OmnyServer the way a server does: as a service, under an
# init, installed with `omnyserver service install`. Used by
# `example/docker_fleet/compose.service.yaml`.
#
# systemd is PID 1 here, so the container's command belongs to init and the
# role's flags cannot come from `command:` — they come from the install script
# the bootstrap unit runs. That is the cost of the honest arrangement, and the
# reason the simpler compose file still exists beside it.
FROM debian:stable-slim AS service

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       systemd systemd-sysv dbus openssl ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  # Nothing here has a console, and a container is not a login host.
  && rm -f /lib/systemd/system/multi-user.target.wants/getty.target \
  && systemctl mask getty.target console-getty.service

COPY --from=build /src/omnyserver /usr/local/bin/omnyserver
COPY docker/omnyserver-bootstrap.service /etc/systemd/system/
RUN systemctl enable omnyserver-bootstrap.service

# systemd wants SIGRTMIN+3 to shut down cleanly; SIGTERM leaves it to time out.
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]

# ---------------------------------------------------------------------------
# The browser dashboard: `omnyserver_web` compiled to JavaScript. It has no
# backend of its own — the page calls the Hub's REST API directly — so serving
# it is serving a directory of static files.
FROM dart:stable AS dashboard-build

WORKDIR /src
COPY . .

WORKDIR /src/omnyserver_web
# Built against the omnyserver in this checkout rather than the last published
# release, so the dashboard and the Hub it talks to are the same version.
RUN printf 'dependency_overrides:\n  omnyserver:\n    path: ..\n' \
  > pubspec_overrides.yaml
RUN dart pub get
# The xterm bundle and the shared stylesheets, which live in omnyshell_web.
RUN dart run omnyshell_web:copy_assets
RUN dart run build_runner build --release --output build

# dart2js emits *no output at all* for an entrypoint whose graph reaches an
# unsupported SDK library such as dart:io: the build succeeds and the page is
# simply blank. A healthy bundle is a few hundred KB.
RUN test "$(wc -c < build/web/main.dart.js)" -gt 100000 \
  || (echo "dart2js produced no real bundle — something pulled in dart:io" \
      && exit 1)

FROM nginx:alpine AS dashboard

COPY --from=dashboard-build /src/omnyserver_web/build/web /usr/share/nginx/html
