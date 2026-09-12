# The image the container integration tests run OmnyServer from.
#
# Built by `test/docker/fleet.dart` (see `OmnyFleet.start`), not by CI directly.
# One binary serves every role — Hub, node and CLI are the same executable — so
# a test fleet is several containers of one image with different arguments.
#
# Two runtime targets, because "what a node can see on its host" is itself
# something worth testing:
#
#   runtime — Debian slim, nothing installed. A node here detects no
#             capabilities, which is the honest answer for a bare host.
#   sdk     — the Dart image, so `dart` is on the PATH. A node here advertises
#             the dart capability without anything being installed for the test.

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

COPY --from=build /src/omnyserver /usr/local/bin/omnyserver
ENTRYPOINT ["/usr/local/bin/omnyserver"]

# ---------------------------------------------------------------------------
FROM dart:stable AS sdk

COPY --from=build /src/omnyserver /usr/local/bin/omnyserver
ENTRYPOINT ["/usr/local/bin/omnyserver"]
