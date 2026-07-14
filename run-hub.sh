#!/bin/bash
# Start a local OmnyServer Hub with dev certs and demo grants.
#
# The Hub serves ONE TLS port: nodes upgrade to a WebSocket on $NODE_PATH, and
# the REST API / /metrics are on the same host and port over HTTPS.
#
# Usage: ./run-hub.sh [extra omnyserver flags...]
#   e.g. ./run-hub.sh --shell        # also serve OmnyShell nodes on /shell
# Override with env vars: OMNYSERVER_HOST, OMNYSERVER_PORT, OMNYSERVER_NODE_PATH,
# OMNYSERVER_CERT, OMNYSERVER_KEY, OMNYSERVER_GRANT, OMNYSERVER_API_TOKEN,
# OMNYSERVER_CORS_ORIGIN.
#
# A browser is always a different origin than the Hub, so a web dashboard needs
# its origin allow-listed here or every API call fails CORS:
#   OMNYSERVER_CORS_ORIGIN=https://omnygrid.github.io ./run-hub.sh
set -euo pipefail

HOST="${OMNYSERVER_HOST:-127.0.0.1}"
PORT="${OMNYSERVER_PORT:-8443}"
NODE_PATH="${OMNYSERVER_NODE_PATH:-/node}"
CERT="${OMNYSERVER_CERT:-certs/server.crt}"
KEY="${OMNYSERVER_KEY:-certs/server.key}"
API_TOKEN="${OMNYSERVER_API_TOKEN:-api-secret}"

# Demo grants: "principal:token:roles" (space-separated for multiple).
GRANTS="${OMNYSERVER_GRANT:-alice:admin-token:admin node-account:node-token:node}"

# Browser origins allowed to call the HTTP API (space-separated for multiple).
CORS_ORIGINS="${OMNYSERVER_CORS_ORIGIN:-}"

if [ ! -f "$CERT" ]; then
  echo "Generating dev certificates..."
  tool/gen-dev-certs.sh
fi

dart pub get

GRANT_ARGS=()
for g in $GRANTS; do
  GRANT_ARGS+=(--grant "$g")
done

CORS_ARGS=()
for o in $CORS_ORIGINS; do
  CORS_ARGS+=(--cors-origin "$o")
done

# "$@" forwards anything else straight through (e.g. --shell).
exec dart run bin/omnyserver.dart hub start \
  --host "$HOST" --port "$PORT" \
  --node-path "$NODE_PATH" \
  --cert "$CERT" --key "$KEY" \
  --api-token "$API_TOKEN" \
  "${GRANT_ARGS[@]}" "${CORS_ARGS[@]}" "$@"
